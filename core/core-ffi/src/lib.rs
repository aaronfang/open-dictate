use core_audio::{PcmChunk, SampleFormat};
use core_llm::rules::RuleBasedPostProcessor;
use core_pipeline::{DictationContext, DictationPipeline, PipelineConfig};
use core_stt::whisper_cpp::{WhisperCppConfig, WhisperCppProvider};
use core_store::Store;
use std::sync::Arc;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Clone)]
pub struct DictateOptions {
    pub wav_path: String,
    pub store_path: String,
    pub app_id: Option<String>,
    pub language_hint: Option<String>,
    pub whisper_cpp_binary: Option<String>,
    pub whisper_model_path: Option<String>,
}

#[derive(Debug, Clone)]
pub struct DictateResult {
    pub session_id: String,
    pub raw_text: String,
    pub final_text: String,
}

fn init_tracing() {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::from_default_env())
            .try_init();
    });
}

fn wav_to_pcm_chunks(path: &str) -> anyhow::Result<Vec<PcmChunk>> {
    let mut reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    if spec.channels != 1 || spec.sample_rate != 16_000 || spec.bits_per_sample != 16 {
        anyhow::bail!("expected 16kHz mono 16-bit wav");
    }
    let samples: Vec<i16> = reader.samples::<i16>().collect::<Result<Vec<_>, _>>()?;
    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for s in samples {
        bytes.extend_from_slice(&s.to_le_bytes());
    }
    Ok(vec![PcmChunk {
        sample_rate_hz: 16_000,
        channels: 1,
        format: SampleFormat::I16,
        data: bytes.into(),
        capture_ts_millis: chrono::Utc::now().timestamp_millis(),
    }])
}

pub fn dictate_wav(options: DictateOptions) -> DictateResult {
    init_tracing();

    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async move {
        let store = Arc::new(Store::open(&options.store_path).expect("open store"));

        let cfg = WhisperCppConfig {
            binary: options
                .whisper_cpp_binary
                .clone()
                .or_else(|| std::env::var("WHISPER_CPP_BIN").ok())
                .unwrap_or_else(|| "whisper-cli".to_string()),
            model_path: options
                .whisper_model_path
                .clone()
                .or_else(|| std::env::var("WHISPER_MODEL_PATH").ok())
                .unwrap_or_else(|| "models/ggml-base.en.bin".to_string()),
            extra_args: vec![],
        };
        let stt = Arc::new(WhisperCppProvider::new(cfg));
        let rules = Arc::new(RuleBasedPostProcessor::new());

        let pipeline = DictationPipeline::new(
            PipelineConfig {
                enable_rules_postprocess: true,
                enable_llm_postprocess: false,
            },
            store,
            stt,
            Some(rules),
            None,
        );

        let audio = wav_to_pcm_chunks(&options.wav_path).expect("read wav");
        let res = pipeline
            .run(
                audio,
                DictationContext {
                    app_id: options.app_id.clone(),
                    language_hint: options.language_hint.clone(),
                },
            )
            .await
            .expect("pipeline run");

        DictateResult {
            session_id: res.session_id,
            raw_text: res.raw_text,
            final_text: res.final_text,
        }
    })
}

uniffi::include_scaffolding!("open_dictate_core");

