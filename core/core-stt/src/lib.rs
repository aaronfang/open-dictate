use core_audio::PcmChunk;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transcription {
    pub text: String,
    /// Whether this is a final result.
    pub is_final: bool,
    /// Provider-specific metadata (optional).
    #[serde(default)]
    pub meta: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SttRequest {
    pub language_hint: Option<String>,
    pub enable_punctuation: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum SttError {
    #[error("provider not configured: {0}")]
    NotConfigured(String),
    #[error("provider failed: {0}")]
    Provider(String),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

#[async_trait::async_trait]
pub trait SttProvider: Send + Sync {
    fn name(&self) -> &'static str;

    async fn transcribe(&self, audio: Vec<PcmChunk>, req: SttRequest) -> Result<Transcription, SttError>;
}

pub mod whisper_cpp;
pub mod volcengine;

