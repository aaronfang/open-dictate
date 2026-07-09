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

