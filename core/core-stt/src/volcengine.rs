use crate::{SttError, SttProvider, SttRequest, Transcription};
use base64::Engine as _;
use core_audio::PcmChunk;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

/// 火山引擎（豆包语音）流式 ASR Provider。
///
/// 协议是 WebSocket + 二进制消息头 +（可选 gzip）payload，详情见文档：
/// `https://docs.volcengine.com/docs/6561/1354869?lang=zh`
///
/// 实现说明（MVP 取舍）：
/// - 官方 ASR v3 大模型链路包含二进制封包协议（header + payload size + gzip payload）。
/// - 为了尽快打通“云端可选 provider”的骨架，这里优先实现「Realtime/OpenAI 兼容事件流」的 WebSocket 形态
///   （见：`https://www.volcengine.com/docs/6559/2310293?lang=zh`），它是 JSON 事件协议，集成成本更低。
/// - 若你需要严格对齐 v3 二进制协议，可在此文件基础上增加第二种 transport（按 `params` 开关选择）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolcengineAsrConfig {
    pub ws_url: String,
    /// Token 鉴权：`Authorization: Bearer {token}`
    pub bearer_token: Option<String>,

    /// 业务参数（appid / resource id / cluster 等）不同产品线字段差异较大，
    /// 这里先预留一个自由 JSON 配置块，便于后续按文档补齐。
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Debug)]
pub struct VolcengineAsrProvider {
    cfg: VolcengineAsrConfig,
}

impl VolcengineAsrProvider {
    pub fn new(cfg: VolcengineAsrConfig) -> Self {
        Self { cfg }
    }
}

#[async_trait::async_trait]
impl SttProvider for VolcengineAsrProvider {
    fn name(&self) -> &'static str {
        "volcengine-asr"
    }

    async fn transcribe(&self, audio: Vec<PcmChunk>, req: SttRequest) -> Result<Transcription, SttError> {
        let bearer = if let Some(t) = self.cfg.bearer_token.clone() {
            t
        } else {
            return Err(SttError::NotConfigured(
                "missing bearer_token for volcengine ASR".into(),
            ));
        };

        // Join audio bytes (assumes pcm16 chunks; conversion is handled by shell layer in MVP).
        let mut pcm = Vec::<u8>::new();
        for c in &audio {
            pcm.extend_from_slice(c.data.as_ref());
        }

        // Realtime API style websocket: typically `wss://$BASE_URL/realtime?intent=transcription&model=$MODEL_NAME`
        // See: https://www.volcengine.com/docs/6559/2310293?lang=zh
        let mut request = self
            .cfg
            .ws_url
            .clone()
            .into_client_request()
            .map_err(|e| SttError::Provider(format!("bad ws_url: {e}")))?;
        request
            .headers_mut()
            .insert("Authorization", format!("Bearer {bearer}").parse().unwrap());

        let (ws, _resp) = tokio_tungstenite::connect_async(request)
            .await
            .map_err(|e| SttError::Provider(format!("ws connect failed: {e}")))?;
        let (mut sink, mut stream) = ws.split();

        // session.update (best-effort, shape follows OpenAI realtime style)
        let mut session = serde_json::json!({
            "type": "session.update",
            "session": {
                "input_audio_format": "pcm16",
                "input_audio_transcription": {
                    "model": self.cfg.params.get("model").cloned().unwrap_or_else(|| serde_json::json!("asr")),
                }
            }
        });
        if let Some(lang) = req.language_hint.as_ref() {
            session["session"]["input_audio_transcription"]["language"] = serde_json::json!(lang);
        }
        sink.send(tokio_tungstenite::tungstenite::Message::Text(session.to_string().into()))
            .await
            .map_err(|e| SttError::Provider(format!("ws send session.update failed: {e}")))?;

        // audio append + commit
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pcm);
        let append = serde_json::json!({
            "type": "input_audio_buffer.append",
            "audio": b64
        });
        sink.send(tokio_tungstenite::tungstenite::Message::Text(append.to_string().into()))
            .await
            .map_err(|e| SttError::Provider(format!("ws send append failed: {e}")))?;

        let commit = serde_json::json!({ "type": "input_audio_buffer.commit" });
        sink.send(tokio_tungstenite::tungstenite::Message::Text(commit.to_string().into()))
            .await
            .map_err(|e| SttError::Provider(format!("ws send commit failed: {e}")))?;

        // Wait for a completed event. Different gateways may use different event types;
        // we match a few known ones.
        let mut final_text: Option<String> = None;
        while let Some(msg) = stream.next().await {
            let msg = msg.map_err(|e| SttError::Provider(format!("ws recv failed: {e}")))?;
            let text: String = match msg {
                tokio_tungstenite::tungstenite::Message::Text(t) => t.to_string(),
                tokio_tungstenite::tungstenite::Message::Binary(b) => String::from_utf8_lossy(&b).to_string(),
                tokio_tungstenite::tungstenite::Message::Close(_) => break,
                _ => continue,
            };

            let v: serde_json::Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let t = v.get("type").and_then(|x| x.as_str()).unwrap_or("");

            // Examples from doc:
            // - conversation.item.input_audio_transcription.completed
            // - conversation.item.input_audio_transcription.result
            // - conversation.item.input_audio_transcription.delta
            if t.ends_with(".completed") || t.ends_with(".result") {
                // Best-effort extraction.
                if let Some(s) = v
                    .pointer("/transcript")
                    .and_then(|x| x.as_str())
                    .or_else(|| v.pointer("/item/content/0/transcript").and_then(|x| x.as_str()))
                    .or_else(|| v.pointer("/transcription/text").and_then(|x| x.as_str()))
                {
                    final_text = Some(s.to_string());
                    break;
                }
            }
        }

        let text = final_text.unwrap_or_default();
        Ok(Transcription {
            text,
            is_final: true,
            meta: serde_json::json!({ "provider": self.name(), "ws_url": self.cfg.ws_url }),
        })
    }
}

