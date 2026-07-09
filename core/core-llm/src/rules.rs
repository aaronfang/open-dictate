use crate::{PostProcessError, PostProcessRequest, PostProcessResult, PostProcessor};
use tracing::debug;

#[derive(Debug, Default)]
pub struct RuleBasedPostProcessor {
    /// Filler words to remove (case-insensitive, token-based).
    filler_words: Vec<&'static str>,
}

impl RuleBasedPostProcessor {
    pub fn new() -> Self {
        Self {
            filler_words: vec![
                "um", "uh", "you know", "like", // EN
                "额", "嗯", "呃", "就是", "你知道", "然后", // ZH (very rough)
            ],
        }
    }

    fn remove_fillers(&self, s: &str) -> String {
        let mut out = s.to_string();
        for w in &self.filler_words {
            // naive replace; good enough for MVP; later upgrade to tokenization.
            out = out.replace(w, "");
            // case-insensitive for ASCII
            out = out.replace(&w.to_ascii_uppercase(), "");
            out = out.replace(&w.to_ascii_lowercase(), "");
        }
        out
    }

    fn normalize_whitespace(&self, s: &str) -> String {
        s.split_whitespace().collect::<Vec<_>>().join(" ")
    }
}

#[async_trait::async_trait]
impl PostProcessor for RuleBasedPostProcessor {
    fn name(&self) -> &'static str {
        "rules"
    }

    async fn process(&self, input: String, _req: PostProcessRequest) -> Result<PostProcessResult, PostProcessError> {
        debug!(processor = self.name(), "rule-based post process");
        let mut text = input;
        text = self.remove_fillers(&text);
        text = self.normalize_whitespace(&text);
        Ok(PostProcessResult {
            text,
            meta: serde_json::json!({ "mode": "rules" }),
        })
    }
}

