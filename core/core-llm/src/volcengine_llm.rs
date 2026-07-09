use crate::{PostProcessError, PostProcessRequest, PostProcessResult, PostProcessor};
use serde::{Deserialize, Serialize};

/// 火山引擎（豆包）文本润色 Provider（骨架）。
///
/// MVP：先把配置/接口落地；后续按具体模型 API（以及鉴权方式）补齐实现。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolcengineLlmConfig {
    pub base_url: String,
    pub api_key: Option<String>,
    pub model: String,
    #[serde(default)]
    pub extra: serde_json::Value,
}

#[derive(Debug)]
pub struct VolcengineLlmPostProcessor {
    cfg: VolcengineLlmConfig,
    client: reqwest::Client,
}

impl VolcengineLlmPostProcessor {
    pub fn new(cfg: VolcengineLlmConfig) -> Self {
        Self {
            cfg,
            client: reqwest::Client::new(),
        }
    }
}

#[derive(Debug, Serialize)]
struct ChatCompletionRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    temperature: f32,
}

#[derive(Debug, Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatChoiceMessage,
}

#[derive(Debug, Deserialize)]
struct ChatChoiceMessage {
    content: String,
}

#[async_trait::async_trait]
impl PostProcessor for VolcengineLlmPostProcessor {
    fn name(&self) -> &'static str {
        "volcengine-llm"
    }

    async fn process(&self, input: String, req: PostProcessRequest) -> Result<PostProcessResult, PostProcessError> {
        let api_key = if let Some(k) = self.cfg.api_key.clone() {
            k
        } else {
            return Err(PostProcessError::NotConfigured(
                "missing volcengine api_key".into(),
            ));
        };

        // 默认按 OpenAI 兼容的 chat completions 形状组织请求。
        // 如你的火山引擎网关是不同路径/字段，可在 `extra` 中配置或再加一层适配器。
        let base = self.cfg.base_url.trim_end_matches('/');
        let url = format!("{base}/v1/chat/completions");

        let tone = req
            .tone
            .as_deref()
            .or(req.app_id.as_deref())
            .unwrap_or("default");
        let conservative_hint = if req.conservative { "尽量少改动" } else { "可以适度润色" };
        let sys = "你是一个写作助手，只输出最终文本，不要解释。";
        let user = format!(
            "请把下面的口语转写文本整理成更自然、清晰、结构化的文字。\n\
要求：删除口头禅与重复词，保留原意不新增事实，补全基础标点，风格参考：{tone}，{conservative_hint}。\n\n\
文本：\n{input}"
        );

        let body = ChatCompletionRequest {
            model: &self.cfg.model,
            messages: vec![
                ChatMessage { role: "system", content: sys },
                ChatMessage { role: "user", content: &user },
            ],
            temperature: 0.2,
        };

        let resp = self
            .client
            .post(url)
            .bearer_auth(api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| PostProcessError::Provider(format!("volcengine llm request failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(PostProcessError::Provider(format!(
                "volcengine llm http {status}: {text}"
            )));
        }

        let out: ChatCompletionResponse = resp
            .json()
            .await
            .map_err(|e| PostProcessError::Provider(format!("volcengine llm bad json: {e}")))?;

        let text = out
            .choices
            .first()
            .map(|c| c.message.content.trim().to_string())
            .unwrap_or_default();

        Ok(PostProcessResult {
            text,
            meta: serde_json::json!({ "provider": "volcengine-openai-compat", "model": self.cfg.model }),
        })
    }
}

