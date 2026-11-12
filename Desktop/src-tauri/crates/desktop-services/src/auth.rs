use crate::{checked, http_client, now, PublicConfig};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};

/// Persistence is OS-protected; a locked/unavailable keyring falls back to RAM only.
pub trait CredentialStore: Send + Sync {
    fn read(&self, account: &str) -> Result<Option<String>>;
    fn write(&self, account: &str, secret: &str) -> Result<()>;
    fn delete(&self, account: &str) -> Result<()>;
}
pub struct OsCredentialStore {
    service: String,
}
impl OsCredentialStore {
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }
}
impl CredentialStore for OsCredentialStore {
    fn read(&self, account: &str) -> Result<Option<String>> {
        match keyring::Entry::new(&self.service, account)?.get_password() {
            Ok(s) => Ok(Some(s)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
    fn write(&self, account: &str, secret: &str) -> Result<()> {
        Ok(keyring::Entry::new(&self.service, account)?.set_password(secret)?)
    }
    fn delete(&self, account: &str) -> Result<()> {
        match keyring::Entry::new(&self.service, account)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Account {
    pub id: String,
    pub email: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Session {
    pub access_token: String,
    pub refresh_token: String,
    #[serde(default)]
    pub expires_at: u64,
    #[serde(default)]
    pub expires_in: u64,
    pub user: Account,
}
impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("user", &self.user)
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct AuthStatus {
    pub account: Option<Account>,
    pub session_only: bool,
}
pub struct AuthService {
    config: PublicConfig,
    client: reqwest::Client,
    store: Arc<dyn CredentialStore>,
    session: Mutex<Option<Session>>,
    session_only: Mutex<bool>,
    refresh_lock: tokio::sync::Mutex<()>,
    key: String,
}
impl AuthService {
    pub fn new(config: PublicConfig, store: Arc<dyn CredentialStore>) -> Result<Self> {
        config.validate()?;
        let key = format!(
            "ai:{}",
            config.supabase_url.as_deref().unwrap_or("unconfigured")
        );
        // Offline/unconfigured builds must not unlock or prompt for the OS
        // credential store merely to open a local book.
        let configured = config.supabase_url.is_some()
            && config
                .supabase_publishable_key
                .as_ref()
                .is_some_and(|key| !key.trim().is_empty());
        let stored = if configured {
            store.read(&key)
        } else {
            Ok(None)
        };
        let session_only = stored.is_err();
        let session = stored
            .ok()
            .flatten()
            .and_then(|s| serde_json::from_str(&s).ok());
        Ok(Self {
            config,
            client: http_client()?,
            store,
            session: Mutex::new(session),
            session_only: Mutex::new(session_only),
            refresh_lock: tokio::sync::Mutex::new(()),
            key,
        })
    }
    pub fn status(&self) -> AuthStatus {
        AuthStatus {
            account: self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .map(|s| s.user.clone()),
            session_only: *self.session_only.lock().unwrap(),
        }
    }
    fn request(&self, path: &str) -> Result<reqwest::RequestBuilder> {
        let url = self
            .config
            .supabase_url
            .as_ref()
            .context("Ask AI sign-in is not configured in this build")?;
        let key = self
            .config
            .supabase_publishable_key
            .as_ref()
            .context("Ask AI sign-in is not configured in this build")?;
        Ok(self
            .client
            .post(format!("{}/auth/v1/{path}", url.trim_end_matches('/')))
            .header("apikey", key))
    }
    pub async fn send_code(&self, email: &str) -> Result<()> {
        if !email.contains('@') || email.len() > 320 {
            bail!("Enter a valid email address");
        }
        checked(
            self.request("otp")?
                .json(&serde_json::json!({"email":email.trim(),"create_user":true}))
                .send()
                .await?,
        )
        .await?;
        Ok(())
    }
    pub async fn verify_code(&self, email: &str, code: &str) -> Result<AuthStatus> {
        let session: Session = checked(
            self.request("verify")?
                .json(&serde_json::json!({"email":email.trim(),"token":code.trim(),"type":"email"}))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        self.save(session)?;
        Ok(self.status())
    }
    fn save(&self, mut session: Session) -> Result<()> {
        if session.access_token.is_empty() || session.refresh_token.is_empty() {
            bail!("Authentication returned an invalid session");
        }
        if session.expires_at == 0 {
            session.expires_at = now() + session.expires_in;
        }
        let persisted = self
            .store
            .write(&self.key, &serde_json::to_string(&session)?)
            .is_ok();
        *self.session_only.lock().unwrap() = !persisted;
        *self.session.lock().unwrap() = Some(session);
        Ok(())
    }
    pub async fn access_token(&self) -> Result<String> {
        // Serialize refreshes: refresh tokens rotate and concurrent use invalidates sessions.
        let _guard = self.refresh_lock.lock().await;
        let session = self
            .session
            .lock()
            .unwrap()
            .clone()
            .context("Sign in to use Ask AI")?;
        if session.expires_at > now() + 60 {
            return Ok(session.access_token);
        }
        let response = self
            .request("token?grant_type=refresh_token")?
            .json(&serde_json::json!({"refresh_token":session.refresh_token}))
            .send()
            .await?;
        if response.status().is_client_error() && response.status().as_u16() != 429 {
            let value: serde_json::Value = response.json().await.unwrap_or_default();
            let code = value["error_code"].as_str().unwrap_or_default();
            if [
                "refresh_token_not_found",
                "refresh_token_already_used",
                "session_not_found",
                "session_expired",
                "user_not_found",
                "user_banned",
                "bad_jwt",
                "invalid_jwt",
            ]
            .contains(&code)
            {
                self.clear()?;
                bail!("Please sign in again to use Ask AI");
            }
            bail!("Could not refresh sign-in; your saved session is preserved");
        }
        let refreshed: Session = checked(response).await?.json().await?;
        let token = refreshed.access_token.clone();
        self.save(refreshed)?;
        Ok(token)
    }
    fn clear(&self) -> Result<()> {
        *self.session.lock().unwrap() = None;
        // Failure is surfaced so a stale persisted session cannot silently reappear on restart.
        self.store.delete(&self.key).context("Signed out for this session, but the OS credential store could not remove the saved session")
    }
    pub async fn sign_out(&self) -> Result<()> {
        let _guard = self.refresh_lock.lock().await;
        let session = self.session.lock().unwrap().clone();
        let cleared = self.clear();
        if let Some(session) = session {
            let _ = self
                .request("logout?scope=local")?
                .bearer_auth(session.access_token)
                .send()
                .await;
        }
        cleared
    }
    pub async fn delete_account(&self) -> Result<()> {
        let token = self.access_token().await?;
        checked(
            self.client
                .delete(format!(
                    "{}/account",
                    self.config.ai_base_url.trim_end_matches('/')
                ))
                .bearer_auth(token)
                .send()
                .await?,
        )
        .await?;
        self.sign_out().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct CountingStore {
        reads: std::sync::atomic::AtomicUsize,
    }
    impl CredentialStore for CountingStore {
        fn read(&self, _: &str) -> Result<Option<String>> {
            self.reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(None)
        }
        fn write(&self, _: &str, _: &str) -> Result<()> {
            Ok(())
        }
        fn delete(&self, _: &str) -> Result<()> {
            Ok(())
        }
    }
    #[test]
    fn unconfigured_and_partial_auth_never_read_secure_storage() {
        let store = Arc::new(CountingStore {
            reads: std::sync::atomic::AtomicUsize::new(0),
        });
        for config in [
            PublicConfig::default(),
            PublicConfig {
                supabase_url: Some("https://project.supabase.co".into()),
                ..PublicConfig::default()
            },
            PublicConfig {
                supabase_publishable_key: Some("sb_publishable_public".into()),
                ..PublicConfig::default()
            },
            PublicConfig {
                supabase_url: Some("https://project.supabase.co".into()),
                supabase_publishable_key: Some(" ".into()),
                ..PublicConfig::default()
            },
        ] {
            let auth = AuthService::new(config, store.clone()).unwrap();
            assert!(auth.status().account.is_none());
            assert!(!auth.status().session_only);
        }
        assert_eq!(store.reads.load(std::sync::atomic::Ordering::SeqCst), 0);
    }
    #[test]
    fn configured_auth_restores_from_secure_storage() {
        let store = Arc::new(CountingStore {
            reads: std::sync::atomic::AtomicUsize::new(0),
        });
        let config = PublicConfig {
            supabase_url: Some("https://project.supabase.co".into()),
            supabase_publishable_key: Some("sb_publishable_public".into()),
            ..PublicConfig::default()
        };
        AuthService::new(config, store.clone()).unwrap();
        assert_eq!(store.reads.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
    struct MemoryStore {
        values: Mutex<std::collections::BTreeMap<String, String>>,
        fail_write: bool,
    }
    impl CredentialStore for MemoryStore {
        fn read(&self, account: &str) -> Result<Option<String>> {
            Ok(self.values.lock().unwrap().get(account).cloned())
        }
        fn write(&self, account: &str, secret: &str) -> Result<()> {
            if self.fail_write {
                bail!("Keyring locked");
            }
            self.values
                .lock()
                .unwrap()
                .insert(account.into(), secret.into());
            Ok(())
        }
        fn delete(&self, account: &str) -> Result<()> {
            self.values.lock().unwrap().remove(account);
            Ok(())
        }
    }
    fn session() -> Session {
        Session {
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            expires_at: now() + 3600,
            expires_in: 3600,
            user: Account {
                id: "user".into(),
                email: Some("reader@example.test".into()),
            },
        }
    }
    #[test]
    fn locked_keyring_falls_back_to_memory_without_plaintext_storage() {
        let store = Arc::new(MemoryStore {
            values: Mutex::new(Default::default()),
            fail_write: true,
        });
        let auth = AuthService::new(PublicConfig::default(), store.clone()).unwrap();
        auth.save(session()).unwrap();
        assert!(auth.status().session_only);
        assert_eq!(auth.status().account.unwrap().id, "user");
        assert!(store.values.lock().unwrap().is_empty());
    }
    #[tokio::test]
    async fn email_code_verification_uses_supabase_rest_and_saves_session() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let response = serde_json::to_string(&session()).unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut bytes = [0; 8192];
            let n = socket.read(&mut bytes).unwrap();
            let request = String::from_utf8_lossy(&bytes[..n]);
            assert!(request.starts_with("POST /auth/v1/verify "));
            assert!(request.to_lowercase().contains("apikey: public-test-key"));
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",response.len(),response).as_bytes()).unwrap();
        });
        let store = Arc::new(MemoryStore {
            values: Mutex::new(Default::default()),
            fail_write: false,
        });
        let mut auth = AuthService::new(PublicConfig::default(), store.clone()).unwrap();
        auth.config.supabase_url = Some(format!("http://{address}"));
        auth.config.supabase_publishable_key = Some("public-test-key".into());
        let status = auth
            .verify_code("reader@example.test", "123456")
            .await
            .unwrap();
        assert_eq!(status.account.unwrap().id, "user");
        assert!(!status.session_only);
        assert_eq!(auth.access_token().await.unwrap(), "access");
        assert_eq!(store.values.lock().unwrap().len(), 1);
        server.join().unwrap();
    }
    #[test]
    fn session_debug_redacts_tokens() {
        let s = Session {
            access_token: "secret-access".into(),
            refresh_token: "secret-refresh".into(),
            expires_at: 0,
            expires_in: 5,
            user: Account {
                id: "a".into(),
                email: None,
            },
        };
        assert!(!format!("{s:?}").contains("secret"));
    }
    #[test]
    fn config_rejects_server_keys_and_insecure_endpoints() {
        let mut c = PublicConfig {
            supabase_publishable_key: Some("sb_secret_private".into()),
            ..Default::default()
        };
        assert!(c.validate().is_err());
        c.supabase_publishable_key = None;
        c.ai_base_url = "http://example.com".into();
        assert!(c.validate().is_err());
    }
}
