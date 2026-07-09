use bytes::Bytes;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleFormat {
    F32,
    I16,
}

#[derive(Debug, Clone)]
pub struct PcmChunk {
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub format: SampleFormat,
    /// Interleaved PCM frames.
    pub data: Bytes,
    pub capture_ts_millis: i64,
}

/// Minimal audio utilities placeholder.
///
/// macOS 录音由外壳层（Swift）完成，本 crate 先定义跨平台可用的数据结构，
/// 后续再补 VAD/重采样/环形缓冲实现。
pub fn validate_chunk(chunk: &PcmChunk) -> anyhow::Result<()> {
    if chunk.sample_rate_hz == 0 {
        anyhow::bail!("sample_rate_hz must be > 0");
    }
    if chunk.channels == 0 {
        anyhow::bail!("channels must be > 0");
    }
    if chunk.data.is_empty() {
        anyhow::bail!("data is empty");
    }
    Ok(())
}

