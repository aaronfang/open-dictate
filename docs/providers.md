# Provider 说明与接入

本项目把能力拆成两个可插拔层：

- **STT Provider**（语音识别）：输入音频 → 输出转写文本
- **PostProcessor**（文本后处理/润色）：输入文本 → 输出更“像人写的”文本

## STT Providers

### 1) `whisper.cpp`（本地）

位置：`core/core-stt/src/whisper_cpp.rs`

实现方式：把录音写成 **16kHz 单声道 i16 WAV**，然后调用本机的 whisper.cpp CLI（例如 `whisper-cli` 或 `main`）。

环境变量（示例）：

```bash
export WHISPER_CPP_BIN="whisper-cli"
export WHISPER_MODEL_PATH="/path/to/ggml-base.bin"
```

示例命令（仅用于验证 provider）：

```bash
cd core
WHISPER_CPP_BIN=whisper-cli WHISPER_MODEL_PATH=/path/to/model.bin \
  cargo run -p core-stt --bin stt_cli -- /path/to/audio_16k_mono.wav
```

### 2) SenseVoiceSmall（本地，CoreML/ANE，macOS 优先）

位置：`apps/macos/Sources/SenseVoiceCoreMLProvider.swift`

推荐参考模型与流水线说明：

- `https://huggingface.co/FluidInference/sensevoice-small-coreml`
- `https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/SenseVoice.md`

说明：这条链路需要 **Preprocessor(FP32/CPU)** + **Encoder+CTC(FP16/ANE)** + 主机端 **greedy CTC decode**。

> 当前仓库内已搭好加载与解码框架；你只需把模型文件放到 App bundle 或配置路径，并补齐输入输出 key 与 bucket padding。

### 3) 火山引擎（云端，可选）

位置：`core/core-stt/src/volcengine.rs`

实现方式：优先支持 **Realtime/OpenAI 兼容事件流** 的 WebSocket JSON 协议形态（便于快速打通），并可按需扩展到 ASR v3 的二进制封包协议。

参考：

- 协议详情（v3 二进制）：`https://docs.volcengine.com/docs/6561/1354869?lang=zh`
- Realtime API（事件流）：`https://www.volcengine.com/docs/6559/2310293?lang=zh`

## PostProcessors

### 1) `rules`（本地，默认）

位置：`core/core-llm/src/rules.rs`

功能：去除常见口头禅、空白归一化（MVP）。

### 2) `local-llm`（本地，可选）

位置：`core/core-llm/src/local_llm.rs`

当前实现：Ollama `/api/generate`（非流式）。

### 3) `deepseek`（云端，可选，macOS Swift MVP）

位置：`apps/macos/Sources/DeepSeekPostProcessor.swift`

当前实现：DeepSeek OpenAI 兼容 `POST /chat/completions`（非流式）。默认关闭；仅发送转写文本，失败/超时回退规则结果。

默认配置：

- Base URL：`https://api.deepseek.com`
- 模型：`deepseek-v4-flash`（可选 `deepseek-v4-pro`）
- 鉴权：`Authorization: Bearer <API Key>`

设置项在 macOS「文本润色」中配置。App 画像的 `tone` 会写入 prompt。

### 4) `volcengine-llm`（云端，可选，Core）

位置：`core/core-llm/src/volcengine_llm.rs`

当前实现：按 OpenAI 兼容的 `/v1/chat/completions` 组织请求；如你的网关字段/路径不同，可做二次适配。

