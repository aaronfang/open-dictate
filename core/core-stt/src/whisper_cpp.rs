use crate::{SttError, SttProvider, SttRequest, Transcription};
use core_audio::{PcmChunk, SampleFormat};
use std::process::Stdio;
use tempfile::NamedTempFile;
use tracing::info;

#[derive(Debug, Clone)]
pub struct WhisperCppConfig {
    /// Path to whisper.cpp binary (e.g. `whisper-cli` or `main`).
    pub binary: String,
    /// Path to ggml model file.
    pub model_path: String,
    /// Extra args appended to CLI invocation.
    pub extra_args: Vec<String>,
}

#[derive(Debug)]
pub struct WhisperCppProvider {
    cfg: WhisperCppConfig,
}

impl WhisperCppProvider {
    pub fn new(cfg: WhisperCppConfig) -> Self {
        Self { cfg }
    }

    fn write_wav_i16_mono_16k(chunks: &[PcmChunk]) -> Result<NamedTempFile, SttError> {
        // For MVP we require: 16kHz, mono, i16 PCM.
        for c in chunks {
            if c.sample_rate_hz != 16_000 || c.channels != 1 || c.format != SampleFormat::I16 {
                return Err(SttError::Provider(
                    "WhisperCppProvider expects 16kHz mono i16 PCM chunks".into(),
                ));
            }
        }

        let mut tmp = NamedTempFile::new().map_err(anyhow::Error::from)?;
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 16_000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::new(&mut tmp, spec).map_err(anyhow::Error::from)?;
        for c in chunks {
            // i16 little-endian.
            let bytes = c.data.as_ref();
            if bytes.len() % 2 != 0 {
                return Err(SttError::Provider("i16 PCM data length must be even".into()));
            }
            for s in bytes.chunks_exact(2) {
                let v = i16::from_le_bytes([s[0], s[1]]);
                writer.write_sample(v).map_err(anyhow::Error::from)?;
            }
        }
        writer.finalize().map_err(anyhow::Error::from)?;
        Ok(tmp)
    }
}

#[async_trait::async_trait]
impl SttProvider for WhisperCppProvider {
    fn name(&self) -> &'static str {
        "whisper.cpp"
    }

    async fn transcribe(&self, audio: Vec<PcmChunk>, req: SttRequest) -> Result<Transcription, SttError> {
        let wav = Self::write_wav_i16_mono_16k(&audio)?;
        let wav_path = wav.path().to_string_lossy().to_string();

        // Common whisper.cpp CLI flags differ across forks/builds.
        // We default to: -m <model> -f <wav> -nt -np (no timestamps / no print progress)
        let mut args = vec![
            "-m".to_string(),
            self.cfg.model_path.clone(),
            "-f".to_string(),
            wav_path,
            "-nt".to_string(),
            "-np".to_string(),
        ];
        if let Some(lang) = req.language_hint.as_ref() {
            args.push("-l".to_string());
            args.push(lang.clone());
        }
        if !req.enable_punctuation {
            // no-op for whisper.cpp; punctuation is model-driven.
        }
        args.extend(self.cfg.extra_args.clone());

        info!(provider = self.name(), binary = %self.cfg.binary, "running whisper.cpp");

        let output = tokio::process::Command::new(&self.cfg.binary)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .await
            .map_err(|e| SttError::Provider(format!("failed to spawn whisper.cpp: {e}")))?;

        if !output.status.success() {
            return Err(SttError::Provider(format!(
                "whisper.cpp exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        // Heuristic: join all stdout lines, strip leading timestamps if any.
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let text = stdout
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .map(|l| {
                // Remove lines like: [00:00:00.000 --> 00:00:02.000]  hello
                if let Some(idx) = l.rfind(']') {
                    if l.starts_with('[') {
                        return l[idx + 1..].trim().to_string();
                    }
                }
                l.to_string()
            })
            .collect::<Vec<_>>()
            .join(" ");

        Ok(Transcription {
            text: text.trim().to_string(),
            is_final: true,
            meta: serde_json::json!({ "raw_stdout": stdout }),
        })
    }
}

