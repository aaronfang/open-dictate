use chrono::Utc;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DictionaryEntry {
    pub phrase: String,
    pub replacement: String,
    pub updated_at_millis: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppProfile {
    pub app_id: String,
    #[serde(default)]
    pub tone: String,
    #[serde(default)]
    pub settings: serde_json::Value,
    pub updated_at_millis: i64,
}

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> anyhow::Result<Self> {
        let conn = Connection::open(path)?;
        let s = Self { conn };
        s.migrate()?;
        Ok(s)
    }

    fn migrate(&self) -> anyhow::Result<()> {
        self.conn.execute_batch(
            r#"
CREATE TABLE IF NOT EXISTS dictionary (
  phrase TEXT PRIMARY KEY,
  replacement TEXT NOT NULL,
  updated_at_millis INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS app_profiles (
  app_id TEXT PRIMARY KEY,
  tone TEXT NOT NULL,
  settings_json TEXT NOT NULL,
  updated_at_millis INTEGER NOT NULL
);
"#,
        )?;
        Ok(())
    }

    pub fn upsert_dictionary(&self, phrase: &str, replacement: &str) -> anyhow::Result<()> {
        let now = Utc::now().timestamp_millis();
        self.conn.execute(
            r#"
INSERT INTO dictionary (phrase, replacement, updated_at_millis)
VALUES (?1, ?2, ?3)
ON CONFLICT(phrase) DO UPDATE SET
  replacement=excluded.replacement,
  updated_at_millis=excluded.updated_at_millis
"#,
            params![phrase, replacement, now],
        )?;
        Ok(())
    }

    pub fn list_dictionary(&self) -> anyhow::Result<Vec<DictionaryEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT phrase, replacement, updated_at_millis FROM dictionary ORDER BY phrase ASC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(DictionaryEntry {
                phrase: r.get(0)?,
                replacement: r.get(1)?,
                updated_at_millis: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn upsert_app_profile(&self, profile: AppProfile) -> anyhow::Result<()> {
        let now = Utc::now().timestamp_millis();
        let settings_json = serde_json::to_string(&profile.settings)?;
        self.conn.execute(
            r#"
INSERT INTO app_profiles (app_id, tone, settings_json, updated_at_millis)
VALUES (?1, ?2, ?3, ?4)
ON CONFLICT(app_id) DO UPDATE SET
  tone=excluded.tone,
  settings_json=excluded.settings_json,
  updated_at_millis=excluded.updated_at_millis
"#,
            params![profile.app_id, profile.tone, settings_json, now],
        )?;
        Ok(())
    }

    pub fn get_app_profile(&self, app_id: &str) -> anyhow::Result<Option<AppProfile>> {
        let mut stmt = self.conn.prepare(
            "SELECT app_id, tone, settings_json, updated_at_millis FROM app_profiles WHERE app_id=?1",
        )?;
        let mut rows = stmt.query(params![app_id])?;
        if let Some(r) = rows.next()? {
            let settings_json: String = r.get(2)?;
            Ok(Some(AppProfile {
                app_id: r.get(0)?,
                tone: r.get(1)?,
                settings: serde_json::from_str(&settings_json).unwrap_or(serde_json::json!({})),
                updated_at_millis: r.get(3)?,
            }))
        } else {
            Ok(None)
        }
    }
}

