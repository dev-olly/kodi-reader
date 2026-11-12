//! Google Drive schema-1 transport. Wire names and hashing match the native Mac client.
//! Fetch commits are explicit: callers persist received changes before advancing a cursor.
use crate::auth::CredentialStore;
use crate::{atomic_write, checked, http_client, now, CancellationToken, PublicConfig};
use anyhow::{bail, Context, Result};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::Arc,
};

pub const CHUNK_SIZE: usize = 16 * 1024 * 1024;
pub const APPLE_EPOCH_OFFSET: f64 = 978_307_200.0;
pub fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
/// Foundation JSONEncoder sortedKeys also escapes forward slashes.
pub fn swift_json<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let value = serde_json::to_value(value)?;
    fn canonical(value: &Value) -> Result<String> {
        Ok(match value {
            Value::Object(map) => {
                let mut keys: Vec<_> = map.keys().collect();
                keys.sort();
                format!(
                    "{{{}}}",
                    keys.into_iter()
                        .map(|k| Ok(format!(
                            "{}:{}",
                            serde_json::to_string(k)?,
                            canonical(&map[k])?
                        )))
                        .collect::<Result<Vec<_>>>()?
                        .join(",")
                )
            }
            Value::Array(values) => format!(
                "[{}]",
                values
                    .iter()
                    .map(canonical)
                    .collect::<Result<Vec<_>>>()?
                    .join(",")
            ),
            Value::Number(n) => {
                let s = n.to_string();
                if let Some(s) = s.strip_suffix(".0") {
                    s.into()
                } else {
                    s
                }
            }
            _ => serde_json::to_string(value)?,
        })
    }
    Ok(canonical(&value)?.replace('/', "\\/").into_bytes())
}
mod data {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        v: &Vec<u8>,
        s: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(v))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        d: D,
    ) -> std::result::Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        STANDARD.decode(s).map_err(serde::de::Error::custom)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SyncEntity {
    pub id: String,
    #[serde(rename = "bookID")]
    pub book_id: String,
    pub kind: String,
    #[serde(with = "data")]
    pub body: Vec<u8>,
    pub modified_at: f64,
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub deleted: bool,
}
impl SyncEntity {
    pub fn from_body(
        book_id: &str,
        kind: &str,
        key: &str,
        body: &Value,
        device_id: &str,
    ) -> Result<Self> {
        if ![
            "book",
            "annotation",
            "bookmark",
            "position",
            "chat",
            "reminder",
        ]
        .contains(&kind)
        {
            bail!("Unsupported sync entity kind");
        }
        Ok(Self {
            id: format!("{kind}:{book_id}:{key}"),
            book_id: book_id.into(),
            kind: kind.into(),
            body: swift_json(body)?,
            modified_at: now() as f64 - APPLE_EPOCH_OFFSET,
            device_id: device_id.into(),
            deleted: false,
        })
    }
    pub fn value(&self) -> Result<Value> {
        Ok(serde_json::from_slice(&self.body)?)
    }
    pub fn logical_id(&self, parents: &[String]) -> Result<String> {
        let mut parents = parents.to_vec();
        parents.sort();
        let mut bytes = swift_json(self)?;
        bytes.extend(parents.join(",").as_bytes());
        Ok(sha256(&bytes))
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BlobManifest {
    pub hash: String,
    pub size: u64,
    pub chunks: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generation: Option<String>,
}
impl BlobManifest {
    pub fn asset_key(&self) -> String {
        match &self.generation {
            Some(g) => format!("{}:{g}", self.hash),
            None => self.hash.clone(),
        }
    }
    pub fn describe(file: &Path) -> Result<Self> {
        use std::io::Read;
        let mut f = std::fs::File::open(file)?;
        let mut hasher = Sha256::new();
        let mut chunks = vec![];
        let mut size = 0;
        loop {
            let mut chunk = vec![0; CHUNK_SIZE];
            let mut n = 0;
            while n < chunk.len() {
                let got = f.read(&mut chunk[n..])?;
                if got == 0 {
                    break;
                }
                n += got;
            }
            if n == 0 {
                break;
            }
            chunk.truncate(n);
            hasher.update(&chunk);
            size += n as u64;
            chunks.push(sha256(&chunk));
        }
        Ok(Self {
            hash: format!("{:x}", hasher.finalize()),
            size,
            chunks,
            generation: None,
        })
    }
    pub fn assemble(&self, directory: &Path, destination: &Path) -> Result<()> {
        use std::io::Write;
        let parent = destination.parent().context("Missing destination parent")?;
        std::fs::create_dir_all(parent)?;
        let mut f = tempfile::NamedTempFile::new_in(parent)?;
        for hash in &self.chunks {
            validate_hash(hash)?;
            let bytes = std::fs::read(directory.join(hash))?;
            if bytes.len() > CHUNK_SIZE || sha256(&bytes) != *hash {
                bail!("Cloud asset failed integrity verification");
            }
            f.write_all(&bytes)?;
        }
        f.as_file().sync_all()?;
        let actual = Self::describe(f.path())?;
        if actual.hash != self.hash || actual.size != self.size || actual.chunks != self.chunks {
            bail!("Cloud asset failed integrity verification");
        }
        f.persist(destination).map_err(|e| e.error)?;
        Ok(())
    }
}
fn validate_hash(hash: &str) -> Result<()> {
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("Invalid asset hash");
    }
    Ok(())
}
pub fn asset_name(scope: &str, blob_hash: &str, hash: &str) -> String {
    format!(
        "kodi-v1-asset-{}",
        sha256(format!("{scope}:{blob_hash}:{hash}").as_bytes())
    )
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub schema: u32,
    #[serde(rename = "logicalID")]
    pub logical_id: String,
    pub entity: SyncEntity,
    pub parents: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ancestor: Option<SyncEntity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<BlobManifest>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Revision {
    #[serde(rename = "fileID")]
    pub file_id: String,
    #[serde(rename = "logicalID")]
    pub logical_id: String,
    pub entity: SyncEntity,
    pub parents: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DriveJournal {
    pub version: u32,
    pub account_id: String,
    pub device_id: String,
    pub cursor: Option<String>,
    pub marker_id: Option<String>,
    pub ai_enabled: bool,
    pub revisions: BTreeMap<String, Vec<Revision>>,
    pub pending: BTreeMap<String, SyncEntity>,
    pub base: BTreeMap<String, SyncEntity>,
    pub delivered: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub requires_acknowledgement: bool,
    #[serde(default)]
    pub deferred: Vec<SyncEntity>,
}
impl DriveJournal {
    pub fn load(root: &Path, account: &str, device_id: &str) -> Result<Self> {
        let path = Self::path(root, account);
        if path.exists() {
            let value: Self = serde_json::from_slice(&std::fs::read(path)?)?;
            if value.version != 1 || value.account_id != account {
                bail!("The Drive journal belongs to another account or schema");
            }
            Ok(value)
        } else {
            Ok(Self {
                version: 1,
                account_id: account.into(),
                device_id: device_id.into(),
                cursor: None,
                marker_id: None,
                ai_enabled: false,
                revisions: BTreeMap::new(),
                pending: BTreeMap::new(),
                base: BTreeMap::new(),
                delivered: BTreeMap::new(),
                requires_acknowledgement: false,
                deferred: vec![],
            })
        }
    }
    pub fn path(root: &Path, account: &str) -> PathBuf {
        root.join("GoogleDrive")
            .join(sha256(account.as_bytes()))
            .join("journal.json")
    }
    pub fn save(&self, root: &Path) -> Result<()> {
        atomic_write(
            &Self::path(root, &self.account_id),
            &serde_json::to_vec(self)?,
        )
    }
    pub fn queue(&mut self, entity: SyncEntity, root: &Path) -> Result<()> {
        self.pending.insert(entity.id.clone(), entity);
        self.save(root)
    }
    pub fn heads(&self, id: &str) -> Vec<Revision> {
        let all = self.revisions.get(id).cloned().unwrap_or_default();
        let parents: BTreeSet<_> = all.iter().flat_map(|r| r.parents.clone()).collect();
        let mut heads: Vec<_> = all
            .into_iter()
            .filter(|r| !parents.contains(&r.logical_id))
            .collect();
        heads.sort_by(|a, b| a.logical_id.cmp(&b.logical_id));
        heads
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DriveAccount {
    #[serde(rename(deserialize = "permissionId"))]
    pub id: String,
    #[serde(rename(deserialize = "emailAddress"))]
    pub email: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DriveCredentials {
    pub refresh_token: String,
    pub account_id: String,
}
#[derive(Deserialize)]
struct GoogleToken {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    expires_in: u64,
}
/// A loopback PKCE authorization is prepared before the system browser opens.
pub struct DriveAuthorization {
    client: reqwest::Client,
    config: PublicConfig,
    store: Arc<dyn CredentialStore>,
    credentials: Option<DriveCredentials>,
    access: Option<(String, u64)>,
}
pub struct PendingDriveAuthorization {
    pub authorization_url: String,
    listener: tokio::net::TcpListener,
    verifier: String,
    state: String,
    redirect: String,
}
impl DriveAuthorization {
    pub fn new(config: PublicConfig, store: Arc<dyn CredentialStore>) -> Result<Self> {
        // A build without its public OAuth client cannot use a saved token;
        // leave secure storage untouched and report Drive disconnected.
        let credentials = if config
            .google_client_id
            .as_ref()
            .is_some_and(|id| !id.trim().is_empty())
        {
            store
                .read("google-drive")
                .ok()
                .flatten()
                .and_then(|s| serde_json::from_str(&s).ok())
        } else {
            None
        };
        Ok(Self {
            client: http_client()?,
            config,
            store,
            credentials,
            access: None,
        })
    }
    pub fn connected_account(&self) -> Option<&str> {
        self.credentials.as_ref().map(|c| c.account_id.as_str())
    }
    fn token_request(&self, fields: &[(&str, String)]) -> Result<reqwest::Request> {
        let id = self
            .config
            .google_client_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .context("Google Drive is not configured in this build")?;
        let mut form = vec![("client_id", id.to_owned())];
        // Google Desktop apps are public clients. Some installed-app clients
        // supply this optional value in addition to PKCE; it is never a server key.
        if let Some(secret) = self
            .config
            .google_client_secret
            .as_deref()
            .map(str::trim)
            .filter(|secret| !secret.is_empty())
        {
            form.push(("client_secret", secret.to_owned()));
        }
        form.extend_from_slice(fields);
        Ok(self
            .client
            .post("https://oauth2.googleapis.com/token")
            .form(&form)
            .build()?)
    }
    fn authorization_code_request(
        &self,
        code: String,
        verifier: String,
        redirect: String,
    ) -> Result<reqwest::Request> {
        self.token_request(&[
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect),
            ("grant_type", "authorization_code".into()),
        ])
    }
    fn refresh_request(&self, refresh_token: String) -> Result<reqwest::Request> {
        self.token_request(&[
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token".into()),
        ])
    }
    pub async fn begin(&self) -> Result<PendingDriveAuthorization> {
        use rand::RngCore;
        let id = self
            .config
            .google_client_id
            .as_ref()
            .context("Google Drive is not configured in this build")?;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let redirect = format!(
            "http://127.0.0.1:{}/callback",
            listener.local_addr()?.port()
        );
        let random = || {
            let mut b = [0u8; 48];
            rand::thread_rng().fill_bytes(&mut b);
            URL_SAFE_NO_PAD.encode(b)
        };
        let verifier = random();
        let state = random();
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let mut url = url::Url::parse("https://accounts.google.com/o/oauth2/v2/auth")?;
        url.query_pairs_mut().extend_pairs([
            ("client_id", id.as_str()),
            ("redirect_uri", &redirect),
            ("response_type", "code"),
            ("scope", "https://www.googleapis.com/auth/drive.appdata"),
            ("access_type", "offline"),
            ("prompt", "consent"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
        ]);
        Ok(PendingDriveAuthorization {
            authorization_url: url.into(),
            listener,
            verifier,
            state,
            redirect,
        })
    }
    pub async fn complete(
        &mut self,
        pending: PendingDriveAuthorization,
        cancel: CancellationToken,
    ) -> Result<DriveAccount> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let callback = async {
            loop {
                let (mut socket, peer) = pending.listener.accept().await?;
                if !peer.ip().is_loopback() {
                    continue;
                }
                let mut bytes = [0; 8192];
                let n = tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    socket.read(&mut bytes),
                )
                .await??;
                let request = std::str::from_utf8(&bytes[..n])?;
                let path = request
                    .lines()
                    .next()
                    .and_then(|s| s.split_whitespace().nth(1))
                    .context("Invalid OAuth callback")?;
                let url = url::Url::parse(&format!("http://localhost{path}"))?;
                if url.path() != "/callback" {
                    let _ = socket
                        .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                        .await;
                    continue;
                }
                let pairs: BTreeMap<_, _> = url
                    .query_pairs()
                    .map(|(k, v)| (k.into_owned(), v.into_owned()))
                    .collect();
                if pairs.get("state") != Some(&pending.state) {
                    let _ = socket
                        .write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                        .await;
                    continue;
                }
                let code = pairs
                    .get("code")
                    .context("Google Drive authorization was declined")?
                    .clone();
                let _=socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 44\r\n\r\nConnected. You can return to Kodi Reader now.").await;
                return Ok::<String, anyhow::Error>(code);
            }
        };
        let code = tokio::select! {_=cancel.cancelled()=>bail!("Drive sign-in cancelled"),r=tokio::time::timeout(std::time::Duration::from_secs(180),callback)=>r??};
        let request = self.authorization_code_request(code, pending.verifier, pending.redirect)?;
        let token: GoogleToken = checked(self.client.execute(request).await?)
            .await?
            .json()
            .await?;
        let account: Value = checked(
            self.client
                .get("https://www.googleapis.com/drive/v3/about")
                .query(&[("fields", "user(permissionId,emailAddress)")])
                .bearer_auth(&token.access_token)
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        let account: DriveAccount = serde_json::from_value(account["user"].clone())?;
        let credentials = DriveCredentials {
            refresh_token: token
                .refresh_token
                .context("Google did not grant offline Drive access")?,
            account_id: account.id.clone(),
        };
        let _ = self
            .store
            .write("google-drive", &serde_json::to_string(&credentials)?);
        self.credentials = Some(credentials);
        self.access = Some((token.access_token, now() + token.expires_in));
        Ok(account)
    }
    pub async fn access_token(&mut self) -> Result<String> {
        if let Some((token, expiry)) = &self.access {
            if *expiry > now() + 60 {
                return Ok(token.clone());
            }
        }
        let credentials = self
            .credentials
            .as_ref()
            .context("Connect Google Drive to sync")?;
        let request = self.refresh_request(credentials.refresh_token.clone())?;
        let response: GoogleToken = checked(self.client.execute(request).await?)
            .await?
            .json()
            .await?;
        if let Some(refresh) = response.refresh_token {
            let c = self.credentials.as_mut().unwrap();
            c.refresh_token = refresh;
            let _ = self.store.write("google-drive", &serde_json::to_string(c)?);
        }
        self.access = Some((response.access_token.clone(), now() + response.expires_in));
        Ok(response.access_token)
    }
    pub fn disconnect(&mut self) -> Result<()> {
        self.credentials = None;
        self.access = None;
        self.store.delete("google-drive")
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileInfo {
    id: String,
    name: Option<String>,
    #[serde(default)]
    app_properties: BTreeMap<String, String>,
    #[serde(default)]
    trashed: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileList {
    files: Vec<FileInfo>,
    next_page_token: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Change {
    file_id: Option<String>,
    #[serde(default)]
    removed: bool,
    file: Option<FileInfo>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangeList {
    changes: Vec<Change>,
    next_page_token: Option<String>,
    new_start_page_token: Option<String>,
}
pub struct DriveTransport {
    client: reqwest::Client,
    token: String,
}
pub struct FetchBatch {
    pub journal: DriveJournal,
    pub received: Vec<SyncEntity>,
}
impl FetchBatch {
    pub fn commit(self, root: &Path) -> Result<DriveJournal> {
        self.journal.save(root)?;
        Ok(self.journal)
    }
}
impl DriveTransport {
    pub fn new(access_token: String) -> Result<Self> {
        Ok(Self {
            client: http_client()?,
            token: access_token,
        })
    }
    async fn get(&self, url: &str) -> Result<reqwest::Response> {
        checked(self.client.get(url).bearer_auth(&self.token).send().await?).await
    }
    pub async fn account(&self) -> Result<DriveAccount> {
        let value: Value = self
            .get("https://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress)")
            .await?
            .json()
            .await?;
        Ok(serde_json::from_value(value["user"].clone())?)
    }
    async fn list(&self, query: &str) -> Result<Vec<FileInfo>> {
        let mut output = vec![];
        let mut page = None::<String>;
        loop {
            let mut request = self
                .client
                .get("https://www.googleapis.com/drive/v3/files")
                .bearer_auth(&self.token)
                .query(&[
                    ("spaces", "appDataFolder"),
                    ("pageSize", "1000"),
                    (
                        "fields",
                        "nextPageToken,files(id,name,appProperties,trashed)",
                    ),
                    ("q", &format!("({query}) and trashed = false")),
                ]);
            if let Some(page) = page {
                request = request.query(&[("pageToken", page)]);
            }
            let batch: FileList = checked(request.send().await?).await?.json().await?;
            output.extend(batch.files);
            page = batch.next_page_token;
            if page.is_none() {
                return Ok(output);
            }
        }
    }
    async fn media(&self, id: &str) -> Result<Vec<u8>> {
        if !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            bail!("Invalid Drive file identifier");
        }
        Ok(self
            .get(&format!(
                "https://www.googleapis.com/drive/v3/files/{id}?alt=media"
            ))
            .await?
            .bytes()
            .await?
            .to_vec())
    }
    async fn upload(
        &self,
        name: &str,
        kind: &str,
        bytes: Vec<u8>,
        existing: Option<&str>,
        properties: Value,
    ) -> Result<FileInfo> {
        let mut props = properties.as_object().cloned().unwrap_or_default();
        props.insert("kodiType".into(), json!(kind));
        let mut metadata =
            json!({"name":name,"mimeType":"application/octet-stream","appProperties":props});
        if existing.is_none() {
            metadata["parents"] = json!(["appDataFolder"]);
        }
        let endpoint = match existing {
            Some(id) => format!("https://www.googleapis.com/upload/drive/v3/files/{id}"),
            None => "https://www.googleapis.com/upload/drive/v3/files".into(),
        };
        let start = checked(
            self.client
                .request(
                    if existing.is_some() {
                        reqwest::Method::PATCH
                    } else {
                        reqwest::Method::POST
                    },
                    endpoint,
                )
                .bearer_auth(&self.token)
                .query(&[
                    ("uploadType", "resumable"),
                    ("fields", "id,name,appProperties"),
                ])
                .header("X-Upload-Content-Type", "application/octet-stream")
                .header("X-Upload-Content-Length", bytes.len())
                .json(&metadata)
                .send()
                .await?,
        )
        .await?;
        let location = start
            .headers()
            .get("Location")
            .context("Drive did not return an upload location")?
            .to_str()?;
        let location = crate::require_https(location)?;
        if location.host_str() != Some("www.googleapis.com") {
            bail!("Untrusted Drive upload location");
        }
        let response = checked(
            self.client
                .put(location)
                .header("Content-Type", "application/octet-stream")
                .body(bytes)
                .send()
                .await?,
        )
        .await?;
        Ok(response.json().await?)
    }
    pub async fn upload_chunk(
        &self,
        hash: &str,
        bytes: Vec<u8>,
        scope: &str,
        blob_hash: &str,
    ) -> Result<()> {
        validate_hash(hash)?;
        if bytes.len() > CHUNK_SIZE || sha256(&bytes) != hash {
            bail!("Cloud chunk failed integrity verification");
        }
        let name = asset_name(scope, blob_hash, hash);
        if self.list(&format!("name = '{name}'")).await?.is_empty() {
            self.upload(&name,"asset",bytes,None,json!({"scopeHash":sha256(scope.as_bytes()),"blobHash":blob_hash,"contentHash":hash})).await?;
        }
        Ok(())
    }
    pub async fn download_chunk(
        &self,
        hash: &str,
        scope: &str,
        blob_hash: &str,
        destination: &Path,
    ) -> Result<()> {
        validate_hash(hash)?;
        let name = asset_name(scope, blob_hash, hash);
        let file = self
            .list(&format!("name = '{name}'"))
            .await?
            .into_iter()
            .next()
            .context("Cloud asset is unavailable")?;
        let bytes = self.media(&file.id).await?;
        if bytes.len() > CHUNK_SIZE || sha256(&bytes) != hash {
            bail!("Cloud chunk failed integrity verification");
        }
        atomic_write(destination, &bytes)
    }
    pub async fn upload_blob(
        &self,
        file: &Path,
        scope: &str,
        generation: Option<String>,
    ) -> Result<BlobManifest> {
        use std::io::Read;
        let mut manifest = BlobManifest::describe(file)?;
        manifest.generation = generation;
        let mut f = std::fs::File::open(file)?;
        for hash in &manifest.chunks {
            let mut bytes = vec![];
            f.by_ref().take(CHUNK_SIZE as u64).read_to_end(&mut bytes)?;
            self.upload_chunk(hash, bytes, scope, &manifest.asset_key())
                .await?;
        }
        Ok(manifest)
    }
    /// Keep immutable local chunks available when a concurrent edit is recovered
    /// under a new annotation ID and must be published in that new scope.
    pub async fn upload_blob_cached(
        &self,
        file: &Path,
        scope: &str,
        generation: Option<String>,
        cache: &Path,
    ) -> Result<BlobManifest> {
        use std::io::Read;
        let manifest = BlobManifest::describe(file)?;
        std::fs::create_dir_all(cache)?;
        let mut source = std::fs::File::open(file)?;
        for hash in &manifest.chunks {
            let mut bytes = Vec::new();
            source
                .by_ref()
                .take(CHUNK_SIZE as u64)
                .read_to_end(&mut bytes)?;
            if sha256(&bytes) != *hash {
                bail!("Local media changed while preparing sync");
            }
            atomic_write(&cache.join(hash), &bytes)?;
        }
        self.upload_blob(file, scope, generation).await
    }
    pub async fn download_blob(
        &self,
        manifest: &BlobManifest,
        scope: &str,
        cache: &Path,
        destination: &Path,
    ) -> Result<()> {
        std::fs::create_dir_all(cache)?;
        for hash in &manifest.chunks {
            let file = cache.join(hash);
            let valid = std::fs::read(&file)
                .map(|b| b.len() <= CHUNK_SIZE && sha256(&b) == *hash)
                .unwrap_or(false);
            if !valid {
                self.download_chunk(hash, scope, &manifest.asset_key(), &file)
                    .await?;
            }
        }
        manifest.assemble(cache, destination)
    }
    pub async fn fetch(
        &self,
        journal: &DriveJournal,
        ai_enabled: bool,
        cache: &Path,
    ) -> Result<FetchBatch> {
        let account = self.account().await?;
        if account.id != journal.account_id {
            bail!("Drive account changed; confirm copying the library before syncing");
        }
        if journal.requires_acknowledgement {
            bail!("Cloud sync needs acknowledgement before it can resume");
        }
        let mut j = journal.clone();
        if let Some(marker) = &j.marker_id {
            let response = self
                .client
                .get(format!(
                    "https://www.googleapis.com/drive/v3/files/{marker}?fields=id,trashed"
                ))
                .bearer_auth(&self.token)
                .send()
                .await?;
            if response.status().as_u16() == 404 {
                bail!("Kodi cloud data was removed; confirm copying your local library");
            }
            let file: FileInfo = checked(response).await?.json().await?;
            if file.trashed {
                bail!("Kodi cloud data was removed; confirm copying your local library");
            }
        } else {
            let file = match self
                .list("name = 'kodi-v1-marker'")
                .await?
                .into_iter()
                .next()
            {
                Some(f) => f,
                None => {
                    self.upload("kodi-v1-marker", "marker", b"1".to_vec(), None, json!({}))
                        .await?
                }
            };
            j.marker_id = Some(file.id);
        }
        if ai_enabled && !j.ai_enabled {
            j.cursor = None;
            j.revisions.clear();
            j.delivered.clear();
        }
        j.ai_enabled = ai_enabled;
        if j.cursor.is_none() {
            let start:Value=self.get("https://www.googleapis.com/drive/v3/changes/startPageToken?spaces=appDataFolder").await?.json().await?;
            j.revisions.clear();
            for file in self.list("'appDataFolder' in parents").await? {
                self.ingest(file, &mut j, cache).await?;
            }
            j.cursor = Some(
                start["startPageToken"]
                    .as_str()
                    .context("Missing Drive change token")?
                    .into(),
            );
        }
        let mut page = j.cursor.clone().unwrap();
        loop {
            let response=self.client.get("https://www.googleapis.com/drive/v3/changes").bearer_auth(&self.token).query(&[("spaces","appDataFolder"),("includeRemoved","true"),("pageSize","1000"),("fields","nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,appProperties,trashed))"),("pageToken",&page)]).send().await?;
            if response.status().as_u16() == 410 {
                bail!("Drive change token expired; reset the journal cursor and perform a full rescan");
            }
            let batch: ChangeList = checked(response).await?.json().await?;
            for change in batch.changes {
                if change.removed || change.file.as_ref().map(|f| f.trashed).unwrap_or(false) {
                    let id = change
                        .file_id
                        .or_else(|| change.file.map(|f| f.id))
                        .unwrap_or_default();
                    if j.marker_id.as_deref() == Some(&id)
                        || j.revisions.values().flatten().any(|r| r.file_id == id)
                    {
                        bail!("Kodi cloud metadata was removed; sync is paused to preserve local changes");
                    }
                } else if let Some(file) = change.file {
                    self.ingest(file, &mut j, cache).await?;
                }
            }
            if let Some(next) = batch.next_page_token {
                page = next;
            } else {
                j.cursor = Some(batch.new_start_page_token.unwrap_or(page));
                break;
            }
        }
        let mut received = vec![];
        for id in j.revisions.keys().cloned().collect::<Vec<_>>() {
            let branches = j.heads(&id);
            let heads: Vec<_> = branches.iter().map(|r| r.logical_id.clone()).collect();
            if heads.is_empty() || j.delivered.get(&id) == Some(&heads) {
                continue;
            }
            let mut resolved = vec![branches[0].entity.clone()];
            for branch in branches.iter().skip(1) {
                let main = resolved.remove(0);
                let ancestor = common_ancestor(&j, &branches);
                let mut values = merge(&main, &branch.entity, ancestor.as_ref())?;
                values.extend(resolved);
                resolved = values;
            }
            for entity in resolved {
                if entity.kind == "chat" && !j.ai_enabled {
                    continue;
                }
                if branches.len() > 1 && entity.kind != "position" {
                    j.pending.insert(entity.id.clone(), entity.clone());
                }
                received.push(entity);
            }
            j.delivered.insert(id, heads);
        }
        Ok(FetchBatch {
            journal: j,
            received,
        })
    }
    async fn ingest(&self, file: FileInfo, j: &mut DriveJournal, cache: &Path) -> Result<()> {
        let name = match file.name {
            Some(n) => n,
            None => return Ok(()),
        };
        if !["kodi-v1-entity-", "kodi-v1-position-", "kodi-v1-reminder-"]
            .iter()
            .any(|p| name.starts_with(p))
        {
            return Ok(());
        }
        if file.app_properties.get("kodiType").map(String::as_str) == Some("chat") && !j.ai_enabled
        {
            return Ok(());
        }
        let mut envelope: Envelope = serde_json::from_slice(&self.media(&file.id).await?)?;
        if let Some(manifest) = &envelope.payload {
            let dir = tempfile::tempdir()?;
            let destination = dir.path().join("payload");
            self.download_blob(
                manifest,
                &format!("payload:{}", envelope.entity.id),
                cache,
                &destination,
            )
            .await?;
            envelope.entity.body = std::fs::read(destination)?;
        }
        if envelope.schema != 1
            || envelope.logical_id != envelope.entity.logical_id(&envelope.parents)?
        {
            bail!("Cloud metadata has an unsupported schema or invalid revision hash");
        }
        let expected = revision_name(&envelope.entity, &envelope.logical_id);
        if name != expected {
            bail!("Cloud revision filename does not match its contents");
        }
        let revisions = j.revisions.entry(envelope.entity.id.clone()).or_default();
        if revisions
            .iter()
            .any(|r| r.logical_id == envelope.logical_id && r.file_id != file.id)
        {
            return Ok(());
        }
        revisions.retain(|r| r.file_id != file.id);
        revisions.push(Revision {
            file_id: file.id,
            logical_id: envelope.logical_id,
            entity: envelope.entity,
            parents: envelope.parents,
        });
        Ok(())
    }
    /// Saves acknowledgements only after metadata upload; failed sends remain queued.
    pub async fn send_pending(&self, j: &mut DriveJournal, root: &Path) -> Result<()> {
        let account = self.account().await?;
        if account.id != j.account_id || j.requires_acknowledgement {
            bail!("Confirm the current Drive account before syncing");
        }
        for entity in j.pending.values().cloned().collect::<Vec<_>>() {
            // The open editor must reconcile its incoming version before this
            // device may publish a descendant of those remote heads.
            if j.deferred.iter().any(|e| e.book_id == entity.book_id) {
                continue;
            }
            if entity.kind == "chat" && !j.ai_enabled {
                continue;
            }
            if !entity.deleted {
                for manifest in entity_blobs(&entity)? {
                    for hash in &manifest.chunks {
                        let cached = root.join("Chunks").join(hash);
                        if cached.is_file() {
                            self.upload_chunk(
                                hash,
                                std::fs::read(cached)?,
                                &entity.id,
                                &manifest.asset_key(),
                            )
                            .await?;
                        }
                    }
                }
            }
            let parents: Vec<_> = j
                .heads(&entity.id)
                .iter()
                .map(|r| r.logical_id.clone())
                .collect();
            let logical_id = entity.logical_id(&parents)?;
            let name = revision_name(&entity, &logical_id);
            let mut stored = entity.clone();
            let payload = if stored.body.len() > 256 * 1024 {
                let temp = tempfile::NamedTempFile::new()?;
                std::fs::write(temp.path(), &stored.body)?;
                let manifest = self
                    .upload_blob(temp.path(), &format!("payload:{}", entity.id), None)
                    .await?;
                stored.body.clear();
                Some(manifest)
            } else {
                None
            };
            let envelope = Envelope {
                schema: 1,
                logical_id: logical_id.clone(),
                entity: stored,
                parents: parents.clone(),
                ancestor: None,
                payload,
            };
            let existing = self
                .list(&format!("name = '{name}'"))
                .await?
                .into_iter()
                .next();
            let file = match existing {
                Some(f) if entity.kind != "position" => f,
                existing => {
                    self.upload(
                        &name,
                        if entity.kind == "position" {
                            "position"
                        } else if entity.kind == "chat" {
                            "chat"
                        } else if entity.kind == "reminder" {
                            "reminder"
                        } else {
                            "entity"
                        },
                        swift_json(&envelope)?,
                        existing.as_ref().map(|f| f.id.as_str()),
                        json!({}),
                    )
                    .await?
                }
            };
            let revisions = j.revisions.entry(entity.id.clone()).or_default();
            revisions.retain(|r| r.file_id != file.id);
            revisions.push(Revision {
                file_id: file.id,
                logical_id,
                entity: entity.clone(),
                parents,
            });
            j.pending.remove(&entity.id);
            j.base.insert(entity.id.clone(), entity);
            j.save(root)?;
        }
        Ok(())
    }
}
fn entity_blobs(entity: &SyncEntity) -> Result<Vec<BlobManifest>> {
    let body = entity.value()?;
    let mut blobs = Vec::new();
    if entity.kind == "book" {
        if let Some(file) = body.get("file") {
            blobs.push(serde_json::from_value(file.clone())?);
        }
    }
    if entity.kind == "annotation" {
        if let Some(file) = body.get("drawing") {
            blobs.push(serde_json::from_value(file.clone())?);
        }
        for (key, fields) in [
            ("sketches", &["scene", "preview"][..]),
            ("audioRecordings", &["recording"][..]),
        ] {
            for item in body[key].as_array().into_iter().flatten() {
                for field in fields {
                    if let Some(manifest) = item.get(*field).filter(|v| !v.is_null()) {
                        blobs.push(serde_json::from_value(manifest.clone())?);
                    }
                }
            }
        }
    }
    Ok(blobs)
}
fn revision_name(entity: &SyncEntity, logical: &str) -> String {
    if entity.kind == "position" {
        format!(
            "kodi-v1-position-{}",
            sha256(format!("{}:{}", entity.id, entity.device_id).as_bytes())
        )
    } else if entity.kind == "reminder" {
        format!("kodi-v1-reminder-{logical}")
    } else {
        format!("kodi-v1-entity-{logical}")
    }
}
fn common_ancestor(j: &DriveJournal, branches: &[Revision]) -> Option<SyncEntity> {
    let first = branches.first()?;
    let all: BTreeMap<_, _> = j
        .revisions
        .get(&first.entity.id)?
        .iter()
        .map(|r| (r.logical_id.clone(), r))
        .collect();
    let ancestry = |id: &str| {
        let mut seen = BTreeSet::new();
        let mut stack = vec![id.to_owned()];
        while let Some(id) = stack.pop() {
            if seen.insert(id.clone()) {
                if let Some(r) = all.get(&id) {
                    stack.extend(r.parents.clone());
                }
            }
        }
        seen
    };
    let mut common = ancestry(&first.logical_id);
    for r in branches.iter().skip(1) {
        common = common
            .intersection(&ancestry(&r.logical_id))
            .cloned()
            .collect();
    }
    let maximal = common.iter().find(|id| {
        !common
            .iter()
            .any(|other| other != *id && ancestry(other).contains(*id))
    })?;
    Some(all.get(maximal)?.entity.clone())
}
fn newer<'a>(a: &'a SyncEntity, b: &'a SyncEntity) -> &'a SyncEntity {
    if a.modified_at > b.modified_at
        || (a.modified_at == b.modified_at && a.device_id > b.device_id)
    {
        a
    } else {
        b
    }
}
pub fn merge(
    local: &SyncEntity,
    remote: &SyncEntity,
    ancestor: Option<&SyncEntity>,
) -> Result<Vec<SyncEntity>> {
    if local.id != remote.id || local.kind != remote.kind {
        bail!("Cannot merge different sync entities");
    }
    let winner = newer(local, remote).clone();
    if local.body == remote.body && local.deleted == remote.deleted {
        return Ok(vec![winner]);
    }
    if let Some(base) = ancestor {
        if local.body == base.body && local.deleted == base.deleted {
            return Ok(vec![preserve_book(remote.clone(), local, remote)?]);
        }
        if remote.body == base.body && remote.deleted == base.deleted {
            return Ok(vec![preserve_book(local.clone(), local, remote)?]);
        }
    }
    if local.kind == "position" {
        return Ok(vec![winner]);
    }
    if local.deleted || remote.deleted {
        let (deleted, surviving) = if local.deleted {
            (local, remote)
        } else {
            (remote, local)
        };
        let mut out = vec![deleted.clone()];
        if !surviving.deleted && ["annotation", "chat"].contains(&surviving.kind.as_str()) {
            out.push(recovered(surviving)?);
        }
        return Ok(out);
    }
    if local.kind == "book" {
        return Ok(vec![preserve_book(winner, local, remote)?]);
    }
    if local.kind == "reminder" {
        if let Some(base) = ancestor {
            let (mut a, mut b, mut c) = (local.value()?, remote.value()?, base.value()?);
            let completed_a = a
                .as_object_mut()
                .context("Invalid reminder")?
                .remove("completedAt");
            let completed_b = b
                .as_object_mut()
                .context("Invalid reminder")?
                .remove("completedAt");
            let completed_c = c
                .as_object_mut()
                .context("Invalid reminder")?
                .remove("completedAt");
            if let Some(mut value) = merge_fields(&a, &b, &c) {
                let completion = if completed_a == completed_b || completed_a == completed_c {
                    completed_b
                } else if completed_b == completed_c || winner == *local {
                    completed_a
                } else {
                    completed_b
                };
                if let Some(completion) = completion {
                    value["completedAt"] = completion;
                }
                value["modifiedAt"] = winner.value()?["modifiedAt"].clone();
                let mut merged = winner.clone();
                merged.body = swift_json(&value)?;
                return Ok(vec![merged]);
            }
        }
    }
    if let Some(base) = ancestor.filter(|_| local.kind == "annotation") {
        let (a, b, c) = (local.value()?, remote.value()?, base.value()?);
        if let Some(value) = merge_fields(&a, &b, &c) {
            let mut entity = winner.clone();
            entity.body = swift_json(&value)?;
            return Ok(vec![entity]);
        }
    }
    if local.kind == "chat" {
        let (a, b) = (local.value()?, remote.value()?);
        if let (Some(a), Some(b)) = (a["messages"].as_array(), b["messages"].as_array()) {
            if a.starts_with(b) {
                return Ok(vec![local.clone()]);
            }
            if b.starts_with(a) {
                return Ok(vec![remote.clone()]);
            }
        }
    }
    if local.kind == "reminder" {
        if local.value()?["title"] == remote.value()?["title"] {
            return Ok(vec![winner]);
        }
        let other = if winner == *local { remote } else { local };
        return Ok(vec![winner, recovered(other)?]);
    }
    if local.kind == "annotation" || local.kind == "chat" {
        return Ok(vec![remote.clone(), recovered(local)?]);
    }
    Ok(vec![winner])
}
fn merge_fields(a: &Value, b: &Value, c: &Value) -> Option<Value> {
    if a == b || a == c {
        return Some(b.clone());
    }
    if b == c {
        return Some(a.clone());
    }
    if let (Some(a), Some(b), Some(c)) = (a.as_object(), b.as_object(), c.as_object()) {
        let keys: BTreeSet<_> = a.keys().chain(b.keys()).chain(c.keys()).collect();
        let mut out = b.clone();
        for key in keys {
            if key == "modifiedAt" || key == "anchorStatus" {
                continue;
            }
            let av = a.get(key).unwrap_or(&Value::Null);
            let bv = b.get(key).unwrap_or(&Value::Null);
            let cv = c.get(key).unwrap_or(&Value::Null);
            let value = merge_fields(av, bv, cv)?;
            if value.is_null() {
                out.remove(key);
            } else {
                out.insert(key.clone(), value);
            }
        }
        return Some(Value::Object(out));
    }
    None
}
fn preserve_book(mut selected: SyncEntity, a: &SyncEntity, b: &SyncEntity) -> Result<SyncEntity> {
    if selected.kind != "book" || a.deleted || b.deleted {
        return Ok(selected);
    }
    let (mut value, a, b) = (selected.value()?, a.value()?, b.value()?);
    if value["file"].is_null() {
        if !a["file"].is_null() {
            value["file"] = a["file"].clone();
        } else if !b["file"].is_null() {
            value["file"] = b["file"].clone();
        }
    }
    let oldest = [a["addedAt"].as_f64(), b["addedAt"].as_f64()]
        .into_iter()
        .flatten()
        .min_by(f64::total_cmp);
    if let Some(oldest) = oldest {
        value["addedAt"] = json!(oldest);
    }
    selected.body = swift_json(&value)?;
    Ok(selected)
}
fn deterministic_uuid(seed: &str) -> String {
    let bytes = Sha256::digest(seed.as_bytes());
    uuid::Uuid::from_bytes(bytes[..16].try_into().unwrap())
        .to_string()
        .to_uppercase()
}
pub fn recovered(source: &SyncEntity) -> Result<SyncEntity> {
    let id = deterministic_uuid(&format!("recovered:{}:{}", source.id, sha256(&source.body)));
    let mut value = source.value()?;
    match source.kind.as_str() {
        "reminder" => {
            value["id"] = json!(id);
            value["title"] = json!(format!(
                "Recovered version: {}",
                value["title"].as_str().unwrap_or_default()
            ));
        }
        "chat" => {
            value["recoveredFrom"] = value["id"].clone();
            value["id"] = json!(id);
            value["title"] = json!(format!(
                "Recovered version: {}",
                value["title"].as_str().unwrap_or_default()
            ));
        }
        "annotation" => {
            value["annotation"]["recoveredFrom"] = value["annotation"]["id"].clone();
            value["annotation"]["id"] = json!(id);
            for (category, prefix) in [
                ("sketches", "recovered-sketch"),
                ("audioRecordings", "recovered-audio"),
            ] {
                let mut remaps = BTreeMap::new();
                if let Some(items) = value["annotation"][category].as_array_mut() {
                    for item in items {
                        if let Some(old) = item["id"].as_str() {
                            let new = deterministic_uuid(&format!("{prefix}:{id}:{old}"));
                            remaps.insert(old.to_owned(), new.clone());
                            item["id"] = json!(new);
                        }
                    }
                }
                if let Some(items) = value[category].as_array_mut() {
                    for item in items {
                        if let Some(new) = item["id"].as_str().and_then(|id| remaps.get(id)) {
                            item["id"] = json!(new);
                        }
                    }
                }
                if let Some(note) = value["annotation"]["note"].as_str() {
                    let mut note = note.to_owned();
                    for (old, new) in remaps {
                        note = remap_media_reference(&note, "kodi-sketch://", &old, &new);
                        note = remap_media_reference(&note, "kodi-audio://", &old, &new);
                    }
                    value["annotation"]["note"] = json!(note);
                }
            }
        }
        _ => return Ok(source.clone()),
    }
    let mut copy = source.clone();
    copy.id = format!("{}:{}:{id}", copy.kind, copy.book_id);
    copy.body = swift_json(&value)?;
    copy.deleted = false;
    Ok(copy)
}
fn remap_media_reference(note: &str, scheme: &str, old: &str, new: &str) -> String {
    let mut out = String::new();
    let mut offset = 0;
    while let Some(found) = note[offset..].find(scheme) {
        let start = offset + found + scheme.len();
        out.push_str(&note[offset..start]);
        let end = start + old.len();
        if let Some(candidate) = note.get(start..end) {
            if candidate.eq_ignore_ascii_case(old) {
                out.push_str(new);
                offset = end;
                continue;
            }
        }
        offset = start;
    }
    out.push_str(&note[offset..]);
    out
}

/// Remove only new, renderer-local PDF data; preserve original Mac pdfRanges untouched.
pub fn portable_body(value: &Value) -> Value {
    let mut output = value.clone();
    fn strip(v: &mut Value) {
        match v {
            Value::Object(map) => {
                for key in [
                    "pdfAnchors",
                    "pdfGeometry",
                    "pdfQuads",
                    "pdfJsAnchor",
                    "pdfTextAnchor",
                    "localPdfAnchor",
                ] {
                    map.remove(key);
                }
                for child in map.values_mut() {
                    strip(child);
                }
            }
            Value::Array(items) => {
                for child in items {
                    strip(child);
                }
            }
            _ => {}
        }
    }
    strip(&mut output);
    output
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
            Ok(Some(serde_json::to_string(&DriveCredentials {
                refresh_token: "saved-refresh".into(),
                account_id: "saved-account".into(),
            })?))
        }
        fn write(&self, _: &str, _: &str) -> Result<()> {
            Ok(())
        }
        fn delete(&self, _: &str) -> Result<()> {
            Ok(())
        }
    }
    #[test]
    fn unconfigured_drive_never_reads_or_restores_a_stale_connection() {
        let store = Arc::new(CountingStore {
            reads: std::sync::atomic::AtomicUsize::new(0),
        });
        for id in [None, Some(" ".to_owned())] {
            let config = PublicConfig {
                google_client_id: id,
                ..PublicConfig::default()
            };
            let drive = DriveAuthorization::new(config, store.clone()).unwrap();
            assert!(drive.connected_account().is_none());
        }
        assert_eq!(store.reads.load(std::sync::atomic::Ordering::SeqCst), 0);
    }
    #[test]
    fn configured_drive_restores_the_os_protected_connection() {
        let store = Arc::new(CountingStore {
            reads: std::sync::atomic::AtomicUsize::new(0),
        });
        let config = PublicConfig {
            google_client_id: Some("public-desktop-client.apps.googleusercontent.com".into()),
            ..PublicConfig::default()
        };
        let drive = DriveAuthorization::new(config, store.clone()).unwrap();
        assert_eq!(drive.connected_account(), Some("saved-account"));
        assert_eq!(store.reads.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
    fn oauth_request_fields(request: reqwest::Request) -> BTreeMap<String, String> {
        assert_eq!(request.method(), reqwest::Method::POST);
        assert_eq!(
            request.url().as_str(),
            "https://oauth2.googleapis.com/token"
        );
        assert_eq!(
            request.headers()[reqwest::header::CONTENT_TYPE],
            "application/x-www-form-urlencoded"
        );
        assert!(request.url().query().is_none());
        url::form_urlencoded::parse(request.body().unwrap().as_bytes().unwrap())
            .map(|(key, value)| (key.into_owned(), value.into_owned()))
            .collect()
    }
    #[test]
    fn installed_oauth_code_exchange_sends_optional_secret_and_pkce_in_post_body() {
        let drive = DriveAuthorization::new(
            PublicConfig {
                google_client_id: Some("fixture-client.apps.googleusercontent.com".into()),
                google_client_secret: Some("fixture+installed/value=&".into()),
                ..PublicConfig::default()
            },
            Arc::new(CountingStore {
                reads: std::sync::atomic::AtomicUsize::new(0),
            }),
        )
        .unwrap();
        let fields = oauth_request_fields(
            drive
                .authorization_code_request(
                    "fixture+code/=".into(),
                    "v".repeat(64),
                    "http://127.0.0.1:32100/callback".into(),
                )
                .unwrap(),
        );
        assert_eq!(
            fields.get("client_secret").map(String::as_str),
            Some("fixture+installed/value=&")
        );
        assert_eq!(
            fields.get("code").map(String::as_str),
            Some("fixture+code/=")
        );
        assert_eq!(fields.get("code_verifier"), Some(&"v".repeat(64)));
        assert_eq!(
            fields.get("redirect_uri").map(String::as_str),
            Some("http://127.0.0.1:32100/callback")
        );
        assert_eq!(
            fields.get("grant_type").map(String::as_str),
            Some("authorization_code")
        );
        assert!(!fields.contains_key("refresh_token"));
    }
    #[test]
    fn installed_oauth_refresh_sends_the_same_optional_client_value_without_pkce_or_code() {
        let drive = DriveAuthorization::new(
            PublicConfig {
                google_client_id: Some("fixture-client.apps.googleusercontent.com".into()),
                google_client_secret: Some("fixture+installed/value=&".into()),
                ..PublicConfig::default()
            },
            Arc::new(CountingStore {
                reads: std::sync::atomic::AtomicUsize::new(0),
            }),
        )
        .unwrap();
        let fields =
            oauth_request_fields(drive.refresh_request("fixture+refresh/=".into()).unwrap());
        assert_eq!(
            fields.get("client_id").map(String::as_str),
            Some("fixture-client.apps.googleusercontent.com")
        );
        assert_eq!(
            fields.get("client_secret").map(String::as_str),
            Some("fixture+installed/value=&")
        );
        assert_eq!(
            fields.get("refresh_token").map(String::as_str),
            Some("fixture+refresh/=")
        );
        assert_eq!(
            fields.get("grant_type").map(String::as_str),
            Some("refresh_token")
        );
        assert!(!fields.contains_key("code"));
        assert!(!fields.contains_key("code_verifier"));
        assert!(!fields.contains_key("redirect_uri"));
    }
    #[test]
    fn oauth_omits_unset_or_blank_installed_client_secret_for_both_grants() {
        for secret in [None, Some(" ".into())] {
            let drive = DriveAuthorization::new(
                PublicConfig {
                    google_client_id: Some("fixture-client.apps.googleusercontent.com".into()),
                    google_client_secret: secret,
                    ..PublicConfig::default()
                },
                Arc::new(CountingStore {
                    reads: std::sync::atomic::AtomicUsize::new(0),
                }),
            )
            .unwrap();
            for request in [
                drive
                    .authorization_code_request(
                        "fixture-code".into(),
                        "v".repeat(64),
                        "http://127.0.0.1:32100/callback".into(),
                    )
                    .unwrap(),
                drive.refresh_request("fixture-refresh".into()).unwrap(),
            ] {
                assert!(!oauth_request_fields(request).contains_key("client_secret"));
            }
        }
    }
    fn entity(note: &str) -> SyncEntity {
        SyncEntity::from_body("epub-sha256:a","annotation","A",&json!({"annotation":{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","note":note,"sketches":[],"audioRecordings":[]}}),"D").unwrap()
    }
    #[test]
    fn wire_data_uses_base64_and_apple_epoch() {
        let e = entity("abc");
        let v: Value = serde_json::from_slice(&swift_json(&e).unwrap()).unwrap();
        assert_eq!(v["body"], STANDARD.encode(&e.body));
        assert!(v["modifiedAt"].as_f64().unwrap() < 1_000_000_000.);
        assert!(v.get("bookID").is_some());
        assert!(v.get("deviceID").is_some());
    }
    #[test]
    fn canonical_escapes_slashes_and_orders_fields() {
        assert_eq!(
            swift_json(&json!({"z":1.0,"a":"a/b"})).unwrap(),
            br#"{"a":"a\/b","z":1}"#
        );
    }
    #[test]
    fn concurrent_notes_preserve_both() {
        let a = entity("one");
        let b = entity("two");
        let out = merge(&a, &b, None).unwrap();
        assert_eq!(out.len(), 2);
        assert_ne!(out[0].id, out[1].id);
        assert_eq!(out[0].value().unwrap()["annotation"]["note"], "two");
        assert_eq!(out[1].value().unwrap()["annotation"]["note"], "one");
        assert_eq!(out[1], recovered(&a).unwrap());
    }
    #[test]
    fn tombstones_do_not_resurrect_deleted_notes() {
        let a = entity("one");
        let mut b = a.clone();
        b.deleted = true;
        let merged = merge(&a, &b, None).unwrap();
        assert!(merged[0].deleted);
        assert_ne!(merged[0].id, merged[1].id);
    }
    #[test]
    fn three_way_merges_independent_fields() {
        let a = json!({"note":"old","color":"green"});
        let b = json!({"note":"new","color":"yellow"});
        let base = json!({"note":"old","color":"yellow"});
        assert_eq!(
            merge_fields(&a, &b, &base),
            Some(json!({"note":"new","color":"green"}))
        );
    }
    #[test]
    fn verified_assembly_preserves_existing_destination_on_corruption() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("book");
        std::fs::write(&dest, b"original").unwrap();
        let hash = sha256(b"good");
        std::fs::write(dir.path().join(&hash), b"bad").unwrap();
        let m = BlobManifest {
            hash: hash.clone(),
            chunks: vec![hash],
            size: 4,
            generation: None,
        };
        assert!(m.assemble(dir.path(), &dest).is_err());
        assert_eq!(std::fs::read(dest).unwrap(), b"original");
    }
    #[test]
    fn accounts_have_separate_journals() {
        let dir = tempfile::tempdir().unwrap();
        assert_ne!(
            DriveJournal::path(dir.path(), "one"),
            DriveJournal::path(dir.path(), "two")
        );
    }
    #[test]
    fn filtering_keeps_mac_pdf_ranges() {
        let v = json!({"locator":{"pdfRanges":[{"pageIndex":0,"location":5,"length":3}],"pdfGeometry":[1,2]}});
        let p = portable_body(&v);
        assert!(p["locator"].get("pdfRanges").is_some());
        assert!(p["locator"].get("pdfGeometry").is_none());
    }
    #[test]
    fn logical_hash_matches_native_swift_fixture() {
        let e = SyncEntity {
            id: "annotation:epub-sha256:abc:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA".into(),
            book_id: "epub-sha256:abc".into(),
            kind: "annotation".into(),
            body: vec![255, 255, 0, 1],
            modified_at: 752692800.1234567,
            device_id: "DEVICE-ONE".into(),
            deleted: false,
        };
        assert_eq!(
            e.logical_id(&["zzz".into(), "aaa".into()]).unwrap(),
            "1b01f7938eed2180bde25694e976c43500a210746965191c3b7627152eae217d"
        );
    }
    #[test]
    fn recovered_media_references_remap_lowercase_uuids() {
        let old = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB";
        let mut source = entity(&format!("[Thought](kodi-audio://{})", old.to_lowercase()));
        let mut body = source.value().unwrap();
        body["annotation"]["audioRecordings"] = json!([{"id":old,"title":"Thought"}]);
        body["audioRecordings"] = json!([{"id":old,"recording":{"hash":"a","size":1,"chunks":[]}}]);
        source.body = swift_json(&body).unwrap();
        let recovered = recovered(&source).unwrap().value().unwrap();
        let new = recovered["annotation"]["audioRecordings"][0]["id"]
            .as_str()
            .unwrap();
        assert_ne!(new, old);
        assert!(recovered["annotation"]["note"]
            .as_str()
            .unwrap()
            .contains(new));
        assert_eq!(recovered["audioRecordings"][0]["id"], new);
    }
    #[test]
    fn concurrent_reminder_completion_preserves_independent_topic_edit() {
        let mut base=SyncEntity::from_body("epub-sha256:a","reminder","AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",&json!({"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","title":"Original","modifiedAt":10}),"A").unwrap();
        base.modified_at = 10.;
        let mut local = base.clone();
        local.body=swift_json(&json!({"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","title":"Edited topic","completedAt":11,"modifiedAt":11})).unwrap();
        local.modified_at = 11.;
        let mut remote = base.clone();
        remote.body=swift_json(&json!({"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","title":"Original","completedAt":12,"modifiedAt":12})).unwrap();
        remote.modified_at = 12.;
        let result = merge(&local, &remote, Some(&base)).unwrap();
        assert_eq!(result.len(), 1);
        let value = result[0].value().unwrap();
        assert_eq!(value["title"], "Edited topic");
        assert_eq!(value["completedAt"], 12);
    }
}
