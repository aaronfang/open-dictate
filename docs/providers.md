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

**macOS 产品路径（已接入）**：`apps/macos/Sources/VolcengineAsrClient.swift`

- 协议：豆包「录音文件极速版」HTTP  
  `POST https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash`
- 鉴权：新版 `X-Api-Key`，或旧版 `X-Api-App-Key` + `X-Api-Access-Key`
- 音频：本地 WAV → Base64 上传（**出网类型：音频**）
- 设置：识别引擎选「火山引擎」；需开通 `volc.bigasr.auc_turbo`
- 文档：https://www.volcengine.com/docs/6561/1631584

**Core 骨架（未接线）**：`core/core-stt/src/volcengine.rs`

- 优先 Realtime/OpenAI 兼容 WebSocket JSON；可扩展 ASR v3 二进制封包
- 参考：v3 二进制 `https://docs.volcengine.com/docs/6561/1354869`；Realtime `https://www.volcengine.com/docs/6559/2310293`

## PostProcessors

### 1) `rules`（本地，默认）

位置：`core/core-llm/src/rules.rs`

功能：去除常见口头禅、空白归一化（MVP）。

### 2) `local-llm`（本地，可选，macOS Swift MVP）

位置：

- macOS：`apps/macos/Sources/LocalLLMManager.swift`、`LocalLLMAssets.swift`
- Core 骨架（Ollama）：`core/core-llm/src/local_llm.rs`（未作为产品路径）

实现：选择「本地模型」后，若资源缺失则自动下载：

1. `llama-server` / `llama-cli`（llama.cpp release `b7375`，按 arch）
2. `qwen2.5-3b-instruct-q4_k_m.gguf`（约 2GB）

落盘目录：`~/Library/Application Support/OpenDictate/llm/`。优先从 **ModelScope** 拉取（国内更快），失败再回退 Hugging Face。推理通过本机 `llama-server`（`127.0.0.1:18765`，OpenAI 兼容 Chat Completions），模型常驻内存。菜单栏与设置页显示下载字节进度；失败/超时回退规则结果。无需安装 Ollama。

### 3) `deepseek`（云端，可选，macOS Swift MVP）

位置：`apps/macos/Sources/DeepSeekPostProcessor.swift`

当前实现：DeepSeek OpenAI 兼容 `POST /chat/completions`（非流式）。默认关闭；仅发送转写文本，失败/超时回退规则结果。

默认配置：

- Base URL：`https://api.deepseek.com`
- 模型：`deepseek-v4-flash`（可选 `deepseek-v4-pro`）
- 鉴权：`Authorization: Bearer <API Key>`

设置项在 macOS「文本润色」中与本地模型三选一。App 画像的 `tone` 会写入 prompt。

### 4) `volcengine-llm`（云端，可选，Core）

位置：`core/core-llm/src/volcengine_llm.rs`

当前实现：按 OpenAI 兼容的 `/v1/chat/completions` 组织请求；如你的网关字段/路径不同，可做二次适配。

