use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SyncPreferences {
    pub version: u32,
    pub mode: String,
    pub sync_ai_history: bool,
    pub account_id: Option<String>,
}
impl Default for SyncPreferences {
    fn default() -> Self {
        Self {
            version: 1,
            mode: "off".into(),
            sync_ai_history: false,
            account_id: None,
        }
    }
}
impl SyncPreferences {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let value: Self = serde_json::from_slice(&std::fs::read(path)?)?;
        if value.version != 1
            || !["off", "notesOnly", "booksAndNotes"].contains(&value.mode.as_str())
        {
            anyhow::bail!("The saved sync preferences are unsupported. Sync is off until you choose it again.");
        }
        Ok(value)
    }
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        use std::io::Write;
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Invalid sync preference path"))?;
        std::fs::create_dir_all(parent)?;
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        temp.write_all(&serde_json::to_vec(self)?)?;
        temp.as_file().sync_all()?;
        temp.persist(path).map_err(|e| e.error)?;
        Ok(())
    }
    pub fn permits_account(&self, account: Option<&str>) -> bool {
        self.mode != "off" && account.is_some() && self.account_id.as_deref() == account
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fresh_install_never_syncs_without_explicit_setup() {
        let prefs = SyncPreferences::default();
        assert!(!prefs.permits_account(None));
        assert!(!prefs.permits_account(Some("account")));
    }
    #[test]
    fn mode_and_history_survive_restart_but_a_different_account_cannot_auto_upload() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("preferences.json");
        let prefs = SyncPreferences {
            mode: "booksAndNotes".into(),
            sync_ai_history: true,
            account_id: Some("first".into()),
            ..Default::default()
        };
        prefs.save(&path).unwrap();
        let restored = SyncPreferences::load(&path).unwrap();
        assert!(restored.sync_ai_history);
        assert!(restored.permits_account(Some("first")));
        assert!(!restored.permits_account(Some("second")));
    }
    #[test]
    fn unsupported_preferences_fail_without_overwriting_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("preferences.json");
        let bytes = br#"{"version":99,"mode":"off","syncAIHistory":false,"accountId":null}"#;
        std::fs::write(&path, bytes).unwrap();
        assert!(SyncPreferences::load(&path).is_err());
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}
