# 隐私模型（Privacy Model）

本项目默认目标：**本地优先（local-first）**，不做遥测，不在云端留存音频数据。

## 数据流概览

### 本地默认路径

- **音频**：由 macOS 外壳（Swift）采集，默认在本地处理
- **识别**：本地 `whisper.cpp`（CLI）或本地 CoreML（SenseVoiceSmall 预留）
- **润色**：规则层默认启用（去口癖/空白规范化）；LLM 润色为可选
- **存储**：仅将个人词典、按 App 画像、必要设置存入本地 SQLite（见 `core/core-store`）

### 云端可选路径（用户显式启用）

当用户选择云端 provider 时，可能会有出网请求：

- **云端 ASR（火山引擎）**：音频内容会发往云端用于识别
- **云端 LLM（DeepSeek / 火山/兼容 OpenAI）**：仅发送文本（识别结果），用于润色/格式化

本项目不会自动启用云端 provider。启用云端后仍建议：

- 使用 **用户自带的 API Key**
- 在 UI 中明确展示 **当前 provider** 与 **出网数据类型（音频/文本）**

macOS 当前已实现：可选 **DeepSeek** 文本润色（默认关；设置页明示「出网类型：文本」）。
## 本地存储内容

SQLite 默认包含：

- `dictionary`：个人词典（短语替换）
- `app_profiles`：按 App 的画像（tone + settings_json）

不存储音频历史；如未来增加“历史记录”功能，应提供：

- 可关闭开关
- 仅本地存储
- 一键清除

