use core_audio::PcmChunk;
use core_llm::{PostProcessRequest, PostProcessor};
use core_stt::{SttProvider, SttRequest};
use core_store::Store;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::info;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineConfig {
    pub enable_rules_postprocess: bool,
    pub enable_llm_postprocess: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DictationContext {
    pub app_id: Option<String>,
    pub language_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DictationResult {
    pub session_id: String,
    pub raw_text: String,
    pub final_text: String,
    #[serde(default)]
    pub meta: serde_json::Value,
}

pub struct DictationPipeline {
    cfg: PipelineConfig,
    store: Arc<Store>,
    stt: Arc<dyn SttProvider>,
    rules: Option<Arc<dyn PostProcessor>>,
    llm: Option<Arc<dyn PostProcessor>>,
}

impl DictationPipeline {
    pub fn new(
        cfg: PipelineConfig,
        store: Arc<Store>,
        stt: Arc<dyn SttProvider>,
        rules: Option<Arc<dyn PostProcessor>>,
        llm: Option<Arc<dyn PostProcessor>>,
    ) -> Self {
        Self {
            cfg,
            store,
            stt,
            rules,
            llm,
        }
    }

    pub async fn run(&self, audio: Vec<PcmChunk>, ctx: DictationContext) -> anyhow::Result<DictationResult> {
        let session_id = Uuid::new_v4().to_string();
        info!(%session_id, stt = self.stt.name(), "dictation start");

        let tone = if let Some(app_id) = ctx.app_id.as_deref() {
            self.store.get_app_profile(app_id)?.map(|p| p.tone)
        } else {
            None
        };

        let stt_req = SttRequest {
            language_hint: ctx.language_hint.clone(),
            enable_punctuation: true,
        };
        let t = self.stt.transcribe(audio, stt_req).await?;
        let raw_text = t.text;

        // Apply personal dictionary replacements (simple substring replace).
        let mut text = raw_text.clone();
        for e in self.store.list_dictionary()? {
            if !e.phrase.is_empty() {
                text = text.replace(&e.phrase, &e.replacement);
            }
        }

        if self.cfg.enable_rules_postprocess {
            if let Some(rules) = self.rules.as_ref() {
                let r = rules
                    .process(
                        text,
                        PostProcessRequest {
                            app_id: ctx.app_id.clone(),
                            tone: tone.clone(),
                            language_hint: ctx.language_hint.clone(),
                            conservative: true,
                        },
                    )
                    .await?;
                text = r.text;
            }
        }

        if self.cfg.enable_llm_postprocess {
            if let Some(llm) = self.llm.as_ref() {
                let r = llm
                    .process(
                        text,
                        PostProcessRequest {
                            app_id: ctx.app_id.clone(),
                            tone: tone.clone(),
                            language_hint: ctx.language_hint.clone(),
                            conservative: false,
                        },
                    )
                    .await?;
                text = r.text;
            }
        }

        Ok(DictationResult {
            session_id,
            raw_text,
            final_text: text,
            meta: serde_json::json!({ "stt_provider": self.stt.name() }),
        })
    }
}

