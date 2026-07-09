use crate::{PostProcessError, PostProcessRequest, PostProcessResult, PostProcessor};
use serde::{Deserialize, Serialize};

/// 本地 LLM 后处理 Provider（骨架）。
///
/// 推荐实现路径：支持 Ollama（HTTP `http://localhost:11434`）或 llama.cpp server。
#[derive(Debug, Clone)]
pub struct LocalLlmConfig {
    pub endpoint: String,
    pub model: String,
}

#[derive(Debug)]
pub struct LocalLlmPostProcessor {
    cfg: LocalLlmConfig,
    client: reqwest::Client,
}

impl LocalLlmPostProcessor {
    pub fn new(cfg: LocalLlmConfig) -> Self {
        Self {
            cfg,
            client: reqwest::Client::new(),
        }
    }
}

#[derive(Debug, Serialize)]
struct OllamaGenerateRequest<'a> {
    model: &'a str,
    prompt: &'a str,
    stream: bool,
}

#[derive(Debug, Deserialize)]
struct OllamaGenerateResponse {
    response: String,
}

#[async_trait::async_trait]
impl PostProcessor for LocalLlmPostProcessor {
    fn name(&self) -> &'static str {
        "local-llm"
    }

    async fn process(&self, input: String, req: PostProcessRequest) -> Result<PostProcessResult, PostProcessError> {
        if self.cfg.endpoint.trim().is_empty() || self.cfg.model.trim().is_empty() {
            return Err(PostProcessError::NotConfigured(
                "missing local LLM endpoint/model".into(),
            ));
        }

        // Ollama-compatible /api/generate (non-streaming).
        // 如果你更偏好 llama.cpp server，可在这里扩展第二种协议实现。
        let tone = req
            .tone
            .as_deref()
            .or(req.app_id.as_deref())
            .unwrap_or("default");
        let conservative_hint = if req.conservative { "尽量少改动" } else { "可以适度润色" };
        let prompt = format!(
            "你是一个写作助手。请把下面的口语转写文本整理成更自然、清晰、结构化的文字：\n\
要求：\n\
- 删除口头禅、重复词\n\
- 保留原意，不要新增事实\n\
- 自动补全基础标点\n\
- 语气/风格参考：{tone}\n\
- {conservative_hint}\n\
\n\
文本：\n{input}\n\n\
只输出最终文本，不要解释。"
        );

        let url = format!("{}/api/generate", self.cfg.endpoint.trim_end_matches('/'));
        let body = OllamaGenerateRequest {
            model: &self.cfg.model,
            prompt: &prompt,
            stream: false,
        };

        let resp = self
            .client
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| PostProcessError::Provider(format!("local llm request failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(PostProcessError::Provider(format!(
                "local llm http {status}: {text}"
            )));
        }

        let out: OllamaGenerateResponse = resp
            .json()
            .await
            .map_err(|e| PostProcessError::Provider(format!("local llm bad json: {e}")))?;

        Ok(PostProcessResult {
            text: out.response.trim().to_string(),
            meta: serde_json::json!({ "provider": "ollama", "model": self.cfg.model }),
        })
    }
}

