# Open Dictate 产品路线图

开源的系统级语音输入工具：全局热键 → 录音 → 语音识别 → 任意 App 光标处上屏，并提供 **本地优先、云端可选** 的文本润色。

本文档描述完整产品愿景、当前进度与分阶段目标。实现细节见 [providers.md](providers.md)、[privacy.md](privacy.md)、[building.md](building.md)。

## 产品愿景

- **系统级听写**：不绑定某一编辑器，在任意输入框可用
- **本地优先**：默认音频与识别不出网；云端能力需用户显式开启
- **可插拔**：STT（识别）与 PostProcessor（润色）可替换
- **可复用内核**：Rust Core + UniFFI，供 macOS / 未来其他平台共用
- **个人化**：个人词典、按 App 语气/格式画像

## 现状快照

| 能力 | 状态 | 说明 |
|------|------|------|
| macOS 菜单栏 + 热键听写 | 已完成 | 默认右 Option 按住说话 |
| 录音 → 识别 → 上屏 | 已完成 | HUD + 剪贴板注入 |
| SenseVoice（CoreML） | 已完成 | Swift 侧完整流水线；启动预热、静音裁剪 |
| whisper.cpp | 已完成 | 调用本机 CLI |
| 权限引导 | 已完成 | 麦克风 / 辅助功能 |
| 设置窗口 | 进行中 | 引擎与路径可配；词典 UI 已接入（Swift MVP） |
| Rust Core / UniFFI | 进行中 | crate 与 Pipeline 已有；macOS 未完整接入打包 |
| 规则润色 / 词典 / App 画像 | 已完成 | 规则+词典+App 画像：Swift MVP 已接听写；P3 收敛 Core |
| 本地/云端 LLM 润色 | 进行中 | DeepSeek 云端（Swift MVP）已接；Ollama 待做 |
| 嘈杂环境降噪 | 计划中 | 见 P1 |
| 跨平台客户端 | 远期 | UniFFI 预留 |

## 分阶段路线图

### P0 — 听写体验打磨（近期 / 基本完成）

目标：安静环境下「按住说话 → 文字上屏」稳定可用。

- [x] 全局热键录音与松键识别
- [x] SenseVoice / whisper.cpp 引擎切换
- [x] 文本注入（记住目标 App、Cmd+V）
- [x] SenseVoice 冷启动预热与就绪提示
- [x] 首尾静音裁剪（缓解 `<|nospeech|>` 空结果）
- [ ] 正式 `.app` 打包与签名分发
- [ ] 设置页与文档状态对齐（SenseVoice 已落地，docs 中过时描述需更新）

### P1 — 嘈杂环境与识别质量

目标：车站、人群等场景下可用率明显提升（无法等同安静环境）。

- [ ] 录音前端：系统 Voice Processing（噪声抑制 / AGC）可开关
- [ ] 轻量预处理：高通滤波、强制语言（如中文）选项
- [ ] 更稳的 VAD（替代纯 RMS 静音裁剪）
- [ ] 可选专用降噪（如 RNNoise）再送入 STT
- [ ] 嘈杂场景策略（可选：加强降噪或切换引擎；默认仍优先 SenseVoice）

### P2 — 文本智能

目标：识别结果更像「写出来的字」，并支持个人习惯。

- [x] 规则后处理默认开启（去口癖、空白归一化）— Swift MVP；P3 收敛 `core/core-llm` rules
- [x] 个人词典管理 UI + 本地 SQLite（schema 对齐 `core-store` `dictionary`；P3 收敛 Core）
- [x] 按 App 画像（语气 / 格式）UI + 本地 `app_profiles`（Swift MVP；P3 收敛 Core）
- [x] 可选云端 LLM 润色（DeepSeek / OpenAI 兼容）；UI 明示出网为「文本」— Swift MVP
- [ ] 可选本地 LLM 润色（Ollama）

### P3 — 架构收敛

目标：外壳与内核统一，避免 Swift / Rust 双轨逻辑漂移。

- [ ] macOS 接入 UniFFI 绑定与动态库（见 `scripts/build_macos_core.sh`）
- [ ] 听写主路径走 Core `Pipeline`（STT → 词典 → 润色）
- [ ] 设置、隐私展示与 Core 配置一致
- [ ] `core-audio`：VAD / 重采样 / 环形缓冲（替代部分外壳临时逻辑）

### P4 — 云端与扩展能力

目标：在用户知情前提下提供云端能力与可选历史。

- [ ] 火山 ASR 完整接入（现有 OpenAI 兼容事件流；可选 v3 二进制 transport）
- [ ] 云端 Provider 开关、API Key、当前出网类型（音频 / 文本）明示
- [ ] 可选「历史记录」：默关、仅本地、可一键清除（见 [privacy.md](privacy.md)）

### P5 — 跨平台（远期）

目标：同一 Core，多端外壳。

- [ ] Windows 外壳（热键 + 注入）
- [ ] Android / 其他（Kotlin 等 UniFFI 消费方）
- [ ] 统一配置与词典同步策略（若需要，仍默认本地）

## 功能清单（按模块）

### 听写与交互

| 功能 | 状态 | 备注 |
|------|------|------|
| 菜单栏常驻 | 已完成 | `apps/macos` |
| 可配置热键 | 计划中 | 当前固定右 Option |
| 按住说话 / 点按切换模式 | 计划中 | 现为按住说话 |
| HUD 状态反馈 | 已完成 | 录音 / 识别 / 错误 |
| 任意 App 上屏 | 已完成 | Accessibility + 剪贴板 |
| 多显示器菜单栏 | 进行中 | 依赖系统策略；文档已提示 |

### 音频前端

| 功能 | 状态 | 备注 |
|------|------|------|
| AVAudioEngine 录音 | 已完成 | |
| 16 kHz mono 转换 | 已完成 | `WavConverter` |
| 静音裁剪 / 峰值归一化 | 已完成 | 缓解 nospeech |
| Voice Processing / 降噪 | 计划中 | P1 |
| 真 VAD | 计划中 | P1 / P3 |

### STT

| 功能 | 状态 | 备注 |
|------|------|------|
| SenseVoice CoreML | 已完成 | 推荐中文场景 |
| whisper.cpp | 已完成 | CLI |
| 模型下载脚本 | 已完成 | `scripts/download_sensevoice_models.sh` |
| 火山云端 ASR | 计划中 | Core 骨架 |
| 引擎自动降级策略 | 远期 | 用户可选，非默认强绑 Whisper |

### 后处理与个人化

| 功能 | 状态 | 备注 |
|------|------|------|
| 规则去口癖 | 已完成 | Swift MVP；Core 有同款逻辑待收敛 |
| 个人词典 | 已完成 | 设置页 CRUD + 听写替换；SQLite 对齐 Core schema |
| App 画像 | 已完成 | 设置页 CRUD；听写按 Bundle ID 套用语气/格式；tone 写入 LLM prompt |
| DeepSeek 润色 | 已完成 | Swift MVP；默认关；失败回退规则结果 |
| Ollama 润色 | 计划中 | Core 骨架 |
| 云端 LLM 润色（火山等） | 计划中 | Core 骨架 |

### 存储、隐私与分发

| 功能 | 状态 | 备注 |
|------|------|------|
| 本地 SQLite | 进行中 | Core + Swift 外壳共用 dictionary schema；路径可配 |
| 无遥测 | 已完成 | 产品原则 |
| 云端显式启用 | 计划中 | 见隐私模型 |
| 历史记录 | 远期 | 可关 / 可清 |
| `.app` 签名分发 | 计划中 | P0 收尾 |
| Rust Core 打进 App | 计划中 | P3 |

## 非目标

- 不做默认遥测或匿名使用统计上传
- 不默认上传音频或转写到云端
- 不以「必须联网」为产品前提
- 不追求替代专业远场会议转写（嘈杂多人场景仅尽力提升）

## 相关文档

- [隐私模型](privacy.md)
- [Provider 说明与接入](providers.md)
- [开发/构建说明](building.md)
