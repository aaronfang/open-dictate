use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PostProcessRequest {
    /// Bundle ID / app identifier used for per-app tone/profile.
    pub app_id: Option<String>,
    /// Resolved per-app tone (from app profile), if any.
    pub tone: Option<String>,
    /// Language hint, e.g. "zh", "en".
    pub language_hint: Option<String>,
    /// If true, keep output terse; otherwise allow more rewriting.
    pub conservative: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PostProcessResult {
    pub text: String,
    #[serde(default)]
    pub meta: serde_json::Value,
}

#[derive(Debug, thiserror::Error)]
pub enum PostProcessError {
    #[error("provider not configured: {0}")]
    NotConfigured(String),
    #[error("provider failed: {0}")]
    Provider(String),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

#[async_trait::async_trait]
pub trait PostProcessor: Send + Sync {
    fn name(&self) -> &'static str;
    async fn process(&self, input: String, req: PostProcessRequest) -> Result<PostProcessResult, PostProcessError>;
}

pub mod rules;
pub mod volcengine_llm;
pub mod local_llm;

