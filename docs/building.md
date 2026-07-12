# 开发与构建

## Rust Core

```bash
cd core
cargo check
```

### UniFFI（为 Swift/Kotlin 生成绑定）

仓库内提供脚本：

```bash
./scripts/build_macos_core.sh
```

它会：

- 构建 `core/core-ffi`（生成 scaffolding）
- 用 `uniffi-bindgen` 生成 Swift 绑定文件到 `apps/macos/Sources/OpenDictateCoreGenerated`

> 注意：macOS 外壳目前还未把生成的 Swift 绑定与动态库完整打包进可运行 `.app`，后续会把这部分接上（典型做法：Xcode Build Phase 调脚本 + Copy Files）。

## macOS 外壳（Swift Package）

```bash
cd apps/macos
swift build
```

推荐用 Xcode 打开 `apps/macos/Package.swift` 运行，方便申请麦克风与辅助功能权限。

### 打包为 `.app`（推荐日常使用）

```bash
./scripts/package_macos_app.sh
open dist/OpenDictate.app
```

可选：

- `--debug`：打 debug 包
- `--with-models`：把 `models/sensevoice` 打进 App（体积大）
- 不带模型时，先安装到 Application Support：

```bash
./scripts/download_sensevoice_models.sh --app-support
```

脚本会生成 **ad-hoc 签名** 的 `dist/OpenDictate.app`。系统设置里麦克风 / 辅助功能应显示为 **OpenDictate**；辅助功能请添加整个 `.app`，不是内部可执行文件。

> 正式公证（Notarization）与 Developer ID 签名尚未接入；当前适合本机与信任环境下的分发。

### Voice Processing

设置 → 语音识别 →「Voice Processing（降噪 / AGC）」**默认关闭**。开启后对 `AVAudioEngine` input 调用 `setVoiceProcessingEnabled`；若设备不支持则自动回退普通麦克风。停录时关闭 VP 并重建引擎，避免橙色麦克风指示灯或系统音量闪避残留。开启期间其他 App 音量被压低是系统通话闪避。

### 能量 VAD

`EnergyVAD` 做自适应噪声底估计、首尾语音裁剪与空录门控。点按切换模式下，「尾静音自动结束」默认开启：检测到说话后约 1.1s 静音即自动停录。