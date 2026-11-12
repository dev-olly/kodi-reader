//! Native desktop integrations. Credentials never cross the renderer boundary.
pub mod ai;
pub mod audio;
pub mod auth;
pub mod hub;
mod playback;
pub mod projection;
pub use playback::PlaybackRequest;
pub mod sync;
pub use hub::ServiceHub;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
pub use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublicConfig {
    pub supabase_url: Option<String>,
    pub supabase_publishable_key: Option<String>,
    pub ai_base_url: String,
    pub ai_model: String,
    pub payments_enabled: bool,
    pub google_client_id: Option<String>,
    /// Optional client value issued for a Google Desktop app (a public client).
    /// Never use a web-server client secret or service-account private key.
    pub google_client_secret: Option<String>,
}
impl Default for PublicConfig {
    fn default() -> Self {
        Self {
            supabase_url: None,
            supabase_publishable_key: None,
            ai_base_url: "https://kodi-reader-ai.fly.dev/v1".into(),
            ai_model: "gpt-5.6-terra".into(),
            payments_enabled: false,
            google_client_id: None,
            google_client_secret: None,
        }
    }
}
impl PublicConfig {
    /// Only public desktop OAuth identifiers / publishable configuration belong here.
    pub fn from_env() -> Result<Self> {
        Self::from_lookup(|name: &str| {
            std::env::var(name).ok().or_else(|| {
                match name {
                    "KODI_SUPABASE_URL" => option_env!("KODI_SUPABASE_URL"),
                    "KODI_SUPABASE_PUBLISHABLE_KEY" => {
                        option_env!("KODI_SUPABASE_PUBLISHABLE_KEY")
                    }
                    "KODI_AI_BASE_URL" => option_env!("KODI_AI_BASE_URL"),
                    "KODI_AI_MODEL" => option_env!("KODI_AI_MODEL"),
                    "KODI_PAYMENTS_ENABLED" => option_env!("KODI_PAYMENTS_ENABLED"),
                    "KODI_GOOGLE_CLIENT_ID" => option_env!("KODI_GOOGLE_CLIENT_ID"),
                    "KODI_GOOGLE_CLIENT_SECRET" => option_env!("KODI_GOOGLE_CLIENT_SECRET"),
                    _ => None,
                }
                .map(str::to_owned)
            })
        })
    }
    fn from_lookup(values: impl Fn(&str) -> Option<String>) -> Result<Self> {
        let get = |name: &str| {
            values(name)
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        };
        let config = Self {
            supabase_url: get("KODI_SUPABASE_URL"),
            supabase_publishable_key: get("KODI_SUPABASE_PUBLISHABLE_KEY"),
            ai_base_url: get("KODI_AI_BASE_URL").unwrap_or_else(|| Self::default().ai_base_url),
            ai_model: get("KODI_AI_MODEL").unwrap_or_else(|| Self::default().ai_model),
            payments_enabled: get("KODI_PAYMENTS_ENABLED").as_deref() == Some("YES"),
            google_client_id: get("KODI_GOOGLE_CLIENT_ID"),
            google_client_secret: get("KODI_GOOGLE_CLIENT_SECRET"),
        };
        config.validate()?;
        Ok(config)
    }
    pub fn validate(&self) -> Result<()> {
        require_https(&self.ai_base_url)?;
        if let Some(url) = &self.supabase_url {
            require_https(url)?;
        }
        if let Some(key) = &self.supabase_publishable_key {
            if key.starts_with("sb_secret_") {
                bail!("Server secret keys must never be configured in the desktop app");
            }
            if let Some(payload) = key.split('.').nth(1) {
                use base64::Engine;
                if let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload)
                {
                    if serde_json::from_slice::<serde_json::Value>(&bytes)
                        .ok()
                        .and_then(|v| v["role"].as_str().map(str::to_owned))
                        .as_deref()
                        == Some("service_role")
                    {
                        bail!("Supabase service_role keys must never be configured in the desktop app");
                    }
                }
            }
        }
        Ok(())
    }
}

pub(crate) fn require_https(value: &str) -> Result<url::Url> {
    let url = url::Url::parse(value)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        bail!("A trusted HTTPS endpoint is required");
    }
    Ok(url)
}
pub(crate) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub(crate) fn http_client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(20))
        .read_timeout(std::time::Duration::from_secs(120))
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}
pub(crate) async fn checked(response: reqwest::Response) -> Result<reqwest::Response> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status();
    // Response bodies can echo private content; errors deliberately carry no raw body.
    bail!("Service request failed (HTTP {})", status.as_u16())
}
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let parent = path.parent().context("Missing parent directory")?;
    std::fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    Ok(())
}

#[cfg(test)]
mod public_config_tests {
    use super::*;
    #[test]
    fn google_installed_client_secret_is_optional_and_blank_values_are_unconfigured() {
        for value in [None, Some(" "), Some(" fixture-installed-client-value ")] {
            let config = PublicConfig::from_lookup(|name| match name {
                "KODI_GOOGLE_CLIENT_ID" => {
                    Some(" fixture-client.apps.googleusercontent.com ".into())
                }
                "KODI_GOOGLE_CLIENT_SECRET" => value.map(str::to_owned),
                _ => None,
            })
            .unwrap();
            assert_eq!(
                config.google_client_id.as_deref(),
                Some("fixture-client.apps.googleusercontent.com")
            );
            assert_eq!(
                config.google_client_secret.as_deref(),
                value.map(str::trim).filter(|value| !value.is_empty())
            );
        }
    }
    #[test]
    fn adding_google_client_configuration_does_not_allow_server_supabase_keys() {
        let config = PublicConfig::from_lookup(|name| match name {
            "KODI_GOOGLE_CLIENT_SECRET" => Some("fixture-installed-client-value".into()),
            "KODI_SUPABASE_PUBLISHABLE_KEY" => Some("sb_secret_fixture_do_not_embed".into()),
            _ => None,
        });
        assert!(config.is_err());
    }
}
