use core_audio::{PcmChunk, SampleFormat};
use core_stt::whisper_cpp::{WhisperCppConfig, WhisperCppProvider};
use core_stt::{SttProvider, SttRequest};

fn wav_to_pcm(path: &str) -> anyhow::Result<Vec<PcmChunk>> {
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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let wav = std::env::args().nth(1).expect("usage: stt_cli <wav_path>");
    let bin = std::env::var("WHISPER_CPP_BIN").unwrap_or_else(|_| "whisper-cli".to_string());
    let model = std::env::var("WHISPER_MODEL_PATH").unwrap_or_else(|_| "models/ggml-base.en.bin".to_string());

    let provider = WhisperCppProvider::new(WhisperCppConfig {
        binary: bin,
        model_path: model,
        extra_args: vec![],
    });

    let audio = wav_to_pcm(&wav)?;
    let res = provider
        .transcribe(
            audio,
            SttRequest {
                language_hint: None,
                enable_punctuation: true,
            },
        )
        .await?;

    println!("{}", res.text);
    Ok(())
}

