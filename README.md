# Open Dictate

开源的系统级语音输入工具：全局热键 → 录音 → 语音识别 → 在任意 App 的光标处上屏，并提供 **本地优先、云端可选** 的文本润色能力。

## 当前状态（MVP）

- **macOS 外壳（Swift/SwiftUI）**：菜单栏 App + `CGEventTap` 全局热键（默认右 Option 按住说话）+ `AVAudioEngine` 录音 + 基础 HUD + 文本注入（Accessibility 优先、剪贴板兜底）
- **Rust Core（可复用内核）**：STT/LLM Provider 抽象、Pipeline 编排、SQLite 本地存储（个人词典/按 App 画像）、UniFFI FFI（为 Swift/Kotlin/C# 预留）
- **本地 STT（基线）**：`whisper.cpp`（通过调用 CLI，可替换成你本机的 `whisper-cli`/`main`）
- **本地 LLM 后处理（可选）**：自动下载 Qwen2.5-3B-Instruct GGUF + llama-cli，本机润色（无需 Ollama）
- **云端可选**：
  - DeepSeek Chat Completions 文本润色（macOS Swift MVP）
  - 火山引擎 Realtime/OpenAI 兼容事件流式 ASR（WebSocket JSON 事件形态，依赖你的网关配置）
  - 火山引擎/OpenAI 兼容 Chat Completions 文本润色（HTTP JSON，Core 骨架）

> 注：为了尽快打通可插拔 provider，本仓库优先实现了“OpenAI 兼容事件流”的 WS 形态；若你要严格对齐火山引擎 v3 ASR 的二进制封包协议，可在 `core/core-stt/src/volcengine.rs` 基础上增加第二种 transport。

## 构建与运行（macOS）

### 1) 构建 Rust Core

```bash
cd core
cargo check
```

### 2) 打包并运行 `.app`（推荐）

```bash
./scripts/package_macos_app.sh
open dist/OpenDictate.app
```

SenseVoice 模型（二选一）：

```bash
./scripts/download_sensevoice_models.sh --app-support
# 或打包时打进 App：
./scripts/package_macos_app.sh --with-models
```

也可用 SPM 直接跑开发二进制：

```bash
cd apps/macos
swift build
```

或用 Xcode 打开 `apps/macos/Package.swift` 运行（方便申请权限与调试）。

### 3) 权限

要实现“全局热键 + 任意 App 上屏”，macOS 需要：

- **麦克风权限**：录音
- **辅助功能（Accessibility）权限**：`CGEventTap` 全局热键监测 + 文本注入（`AXUIElement` / 模拟粘贴）

使用 `.app` 时，请在辅助功能列表中添加 **OpenDictate.app**。
## 文档

- [产品路线图](docs/roadmap.md)
- [隐私模型](docs/privacy.md)
- [Provider 说明与接入](docs/providers.md)
- [开发/构建说明](docs/building.md)

## License

Apache-2.0
