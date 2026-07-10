import AppKit
import Carbon.HIToolbox
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case recognition
    case polish
    case dictionary
    case appProfiles
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "权限与热键"
        case .recognition: return "语音识别"
        case .polish: return "文本润色"
        case .dictionary: return "词典"
        case .appProfiles: return "按应用写法"
        case .storage: return "数据存储"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "lock.shield"
        case .recognition: return "waveform"
        case .polish: return "text.badge.checkmark"
        case .dictionary: return "character.book.closed"
        case .appProfiles: return "app.badge.checkmark"
        case .storage: return "internaldrive"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "授权状态与按住说话热键"
        case .recognition: return "选择引擎与模型参数"
        case .polish: return "规则清理与可选 LLM"
        case .dictionary: return "听写结果中的固定替换"
        case .appProfiles: return "按目标 App 调整语气与格式"
        case .storage: return "本地 SQLite 路径"
        }
    }
}

struct SettingsView: View {
    @StateObject private var settings = AppSettings()
    @ObservedObject var statusController: StatusController
    @State private var selectedPane: SettingsPane = .general
    @State private var dictionaryEntries: [DictionaryEntry] = []
    @State private var newPhrase = ""
    @State private var newReplacement = ""
    @State private var dictionaryError: String?

    @State private var appProfiles: [AppProfile] = []
    @State private var profileError: String?
    @State private var editingProfile: AppProfile?
    @State private var draftAppId = ""
    @State private var draftDisplayName = ""
    @State private var draftTonePreset: AppTonePreset = .neutral
    @State private var draftCustomTone = ""
    @State private var draftStripTrailingPeriod = false
    @State private var draftSkipFillerRemoval = false
    @State private var isAddingProfile = false

    init(statusController: StatusController = StatusController.shared) {
        self.statusController = statusController
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)
                .frame(maxHeight: .infinity)
                .background(SettingsChrome.sidebarFill)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsChrome.detailFill)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            settings.migrateLLMProviderIfNeeded()
            if settings.llmPolishProvider == .local {
                LocalLLMManager.shared.prefetchIfNeeded()
            }
            reloadAllStoreData()
        }
        .onChange(of: settings.storePath) { _, _ in reloadAllStoreData() }
        .onChange(of: selectedPane) { _, pane in
            if pane == .dictionary || pane == .appProfiles || pane == .storage {
                reloadAllStoreData()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 14)

            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsSidebarItem(
                        pane: pane,
                        isSelected: selectedPane == pane
                    ) {
                        selectedPane = pane
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedPane.title)
                        .font(.title2.weight(.semibold))
                    Text(selectedPane.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)

                switch selectedPane {
                case .general:
                    generalPane
                case .recognition:
                    recognitionPane
                case .polish:
                    polishPane
                case .dictionary:
                    dictionaryPane
                case .appProfiles:
                    appProfilesPane
                case .storage:
                    storagePane
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var generalPane: some View {
        SettingsCard(title: "系统权限", footer: "通过 swift run 运行时，系统设置中显示为 OpenDictateMac。") {
            SettingsRow(label: "麦克风") {
                SettingsStatusBadge(
                    text: Permissions.isMicrophoneGranted ? "已授权" : "未授权",
                    tone: Permissions.isMicrophoneGranted ? .ok : .warn
                )
            }
            SettingsRow(label: "辅助功能") {
                SettingsStatusBadge(
                    text: Permissions.isAccessibilityGranted ? "已授权" : "未授权",
                    tone: Permissions.isAccessibilityGranted ? .ok : .warn
                )
            }
            SettingsPathReadOnly(label: "可执行路径", path: Permissions.executablePath)
            HStack(spacing: 10) {
                Button("打开麦克风设置") { Permissions.openMicrophoneSettings() }
                Button("打开辅助功能设置") { Permissions.openAccessibilitySettings() }
            }
        }

        SettingsCard(
            title: "热键",
            footer: "按住热键说话，松开后识别并上屏。不支持 Esc / Command（会干扰取消与粘贴）。更改后立即生效。全局热键与文本注入需要「辅助功能」授权。"
        ) {
            SettingsRow(label: "当前热键") {
                Text(settings.dictationHotkey.settingsLabel)
                    .foregroundStyle(.primary)
            }
            SettingsRow(label: "热键监听") {
                SettingsStatusBadge(
                    text: statusController.hotkeyActive ? "已启动" : "未启动",
                    tone: statusController.hotkeyActive ? .ok : .warn
                )
            }

            Picker("常用热键", selection: hotkeyPresetBinding) {
                ForEach(DictationHotkey.presets) { preset in
                    Text(preset.displayName).tag(Int(preset.keyCode))
                }
                if !DictationHotkey.presets.map(\.keyCode).contains(UInt16(settings.dictationHotkeyKeyCode)) {
                    Text(settings.dictationHotkey.displayName)
                        .tag(settings.dictationHotkeyKeyCode)
                }
            }

            HotkeyCaptureButton(keyCode: $settings.dictationHotkeyKeyCode) { recording in
                if recording {
                    statusController.pauseHotkeyForCapture()
                } else {
                    statusController.resumeHotkeyAfterCapture()
                }
            }

            if settings.dictationHotkeyKeyCode != Int(DictationHotkey.defaultKeyCode) {
                Button("恢复默认（右 Option）") {
                    settings.dictationHotkeyKeyCode = Int(DictationHotkey.defaultKeyCode)
                    statusController.applyDictationHotkeyFromSettings()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var hotkeyPresetBinding: Binding<Int> {
        Binding(
            get: { settings.dictationHotkeyKeyCode },
            set: { newValue in
                settings.dictationHotkeyKeyCode = newValue
                statusController.applyDictationHotkeyFromSettings()
            }
        )
    }

    @ViewBuilder
    private var recognitionPane: some View {
        SettingsCard(title: "识别引擎", footer: "推荐 SenseVoice（本地 CoreML）。whisper.cpp 适合已有 ggml 模型的场景。") {
            Picker("", selection: $settings.sttEngineRaw) {
                ForEach(STTEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        if settings.sttEngine == .senseVoice {
            SettingsCard(title: "常用选项", footer: "开启 ITN 后输出逗号、句号等标点；关闭则为纯文本。听写全程本地，不需要网络。") {
                SettingsRow(label: "识别语言") {
                    Picker("", selection: $settings.senseVoiceLanguage) {
                        Text("中文（推荐）").tag("zh")
                        Text("自动").tag("auto")
                        Text("英语").tag("en")
                        Text("粤语").tag("yue")
                        Text("日语").tag("ja")
                        Text("韩语").tag("ko")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                Toggle("标点与数字归一化（ITN）", isOn: $settings.senseVoiceEnableITN)
                SettingsRow(label: "模型状态") {
                    SettingsStatusBadge(
                        text: settings.senseVoiceModelsReady ? "已就绪" : "未下载",
                        tone: settings.senseVoiceModelsReady ? .ok : .warn
                    )
                }
            }

            SettingsCard(title: "高级", footer: "首次使用请运行：./scripts/download_sensevoice_models.sh。首次启动可能编译 Neural Engine（仅一次）。") {
                SettingsPathField(label: "模型目录", text: $settings.senseVoiceModelsPath)
                Toggle("使用 INT8 模型（更小，推荐）", isOn: $settings.senseVoiceUseInt8)
                Toggle("使用 FP32 编码器（无 ANE 时）", isOn: $settings.senseVoiceUseFp32)
            }
        } else {
            SettingsCard(title: "whisper.cpp") {
                SettingsPathField(label: "可执行文件", text: $settings.whisperBinary)
                SettingsPathField(label: "模型路径（ggml *.bin）", text: $settings.whisperModelPath)
                SettingsLabeledField(label: "语言", placeholder: "auto / zh / en", text: $settings.whisperLanguage)
            }
        }
    }

    @ViewBuilder
    private var polishPane: some View {
        SettingsCard(title: "规则后处理", footer: "默认开启。流水线：词典 → 规则 → 可选 LLM → App 格式。") {
            Toggle("去口癖 / 空白归一化", isOn: $settings.enableRulesPostprocess)
        }

        SettingsCard(title: "LLM 润色", footer: "关闭时仅用规则与词典。本地模型不出网；DeepSeek 仅发送转写文本。") {
            Picker("", selection: llmProviderBinding) {
                ForEach(LLMPolishProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        if settings.llmPolishProvider == .local {
            SettingsCard(title: "本地模型", footer: "无需安装 Ollama。首次需下载 \(LocalLLMAssets.modelSizeHint)；国内默认走 ModelScope。失败/超时回退规则结果。") {
                LocalLLMSettingsBlock(
                    settings: settings,
                    localLLM: LocalLLMManager.shared
                )
            }
        }

        if settings.llmPolishProvider == .deepseek {
            SettingsCard(title: "DeepSeek", footer: "失败或超时会回退到规则结果并照常上屏。Key 存于本机 UserDefaults。") {
                SettingsSecureField(label: "API Key", text: $settings.deepSeekApiKey)
                SettingsRow(label: "模型") {
                    Picker("", selection: $settings.deepSeekModel) {
                        Text("deepseek-v4-flash（推荐）").tag("deepseek-v4-flash")
                        Text("deepseek-v4-pro").tag("deepseek-v4-pro")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                Toggle("保守润色（少改动）", isOn: $settings.deepSeekConservative)
                SettingsRow(label: "超时（秒）") {
                    TextField("", value: $settings.deepSeekTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
                SettingsRow(label: "出网类型") {
                    SettingsStatusBadge(text: "文本（识别结果）", tone: .warn)
                }
                if !settings.deepSeekConfigured {
                    Text("请填写 API Key 后才会真正请求。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "高级") {
                SettingsPathField(label: "Base URL", text: $settings.deepSeekBaseURL)
            }
        }
    }

    private var llmProviderBinding: Binding<String> {
        Binding(
            get: {
                let raw = settings.llmPolishProviderRaw.isEmpty
                    ? settings.llmPolishProvider.rawValue
                    : settings.llmPolishProviderRaw
                return LLMPolishProvider.resolve(stored: raw).rawValue
            },
            set: { newValue in
                let provider = LLMPolishProvider.resolve(stored: newValue)
                settings.llmPolishProvider = provider
                if provider == .local {
                    LocalLLMManager.shared.prefetchIfNeeded()
                }
            }
        )
    }

    @ViewBuilder
    private var dictionaryPane: some View {
        SettingsCard(title: "词条", footer: "听写结果中的原文会被替换为对应写法，优先于规则与 LLM。") {
            if let dictionaryError {
                Text(dictionaryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if dictionaryEntries.isEmpty {
                Text("暂无词条")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dictionaryEntries.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Text(entry.phrase)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(entry.replacement)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                deleteDictionaryEntry(entry.phrase)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 8)
                        if index < dictionaryEntries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }

        SettingsCard(title: "添加词条") {
            HStack(alignment: .center, spacing: 10) {
                TextField("原文", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                TextField("替换为", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                Button("添加") { addDictionaryEntry() }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var appProfilesPane: some View {
        SettingsCard(
            title: "已配置",
            footer: "按目标 App 的 Bundle ID 套用语气与格式。开启 LLM 时语气会写入 prompt；格式规则在 LLM 之后仍会生效。"
        ) {
            if let profileError {
                Text(profileError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appProfiles.isEmpty {
                Text("暂无画像")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appProfiles.enumerated()), id: \.element.id) { index, profile in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(profile.resolvedDisplayName)
                                    .fontWeight(.medium)
                                Spacer(minLength: 8)
                                Text(profile.tonePreset.displayName)
                                    .foregroundStyle(.secondary)
                                Button("编辑") { beginEditProfile(profile) }
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    deleteAppProfile(profile.appId)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(profile.appId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text(profileFormatSummary(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        if index < appProfiles.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }

        SettingsCard(
            title: isAddingProfile || editingProfile != nil ? "编辑画像" : "添加画像",
            footer: (isAddingProfile || editingProfile != nil)
                ? nil
                : "先在目标 App 里按住听写热键一次，再点「添加最近听写的 App」。"
        ) {
            if isAddingProfile || editingProfile != nil {
                profileEditor
            } else {
                HStack(spacing: 10) {
                    Button("添加最近听写的 App") { addLastDictationAppProfile() }
                    Button("手动添加") { beginAddProfile() }
                }
            }
        }
    }

    @ViewBuilder
    private var storagePane: some View {
        SettingsCard(title: "本地数据库", footer: "默认仅本地存储词典与画像，不做任何遥测。修改路径后会重新加载词典与画像。") {
            SettingsPathField(label: "SQLite 存储路径", text: $settings.storePath)
        }
    }

    @ViewBuilder
    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabeledField(label: "Bundle ID", placeholder: "com.example.app", text: $draftAppId)
                .disabled(editingProfile != nil)
            SettingsLabeledField(label: "显示名称（可选）", placeholder: "微信", text: $draftDisplayName)
            SettingsRow(label: "语气") {
                Picker("", selection: $draftTonePreset) {
                    ForEach(AppTonePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            if draftTonePreset == .custom {
                SettingsLabeledField(label: "自定义语气", placeholder: "将用于 LLM", text: $draftCustomTone)
            } else {
                Text(draftTonePreset.defaultToneText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("聊天场景：去掉句末句号", isOn: $draftStripTrailingPeriod)
            Toggle("开发工具：保留口癖、少做规则清理", isOn: $draftSkipFillerRemoval)
            HStack(spacing: 10) {
                Button("保存") { saveProfileDraft() }
                    .disabled(draftAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消") { cancelProfileEditor() }
            }
        }
    }

    // MARK: - Store helpers

    private func profileFormatSummary(_ profile: AppProfile) -> String {
        var parts: [String] = []
        if profile.format.stripTrailingPeriod { parts.append("去句末句号") }
        if profile.format.skipFillerRemoval { parts.append("少改口癖") }
        if parts.isEmpty { return "格式：默认" }
        return "格式：" + parts.joined(separator: " · ")
    }

    private func reloadAllStoreData() {
        reloadDictionary()
        reloadAppProfiles()
    }

    private func reloadDictionary() {
        do {
            let store = try LocalStore(path: settings.storePath)
            dictionaryEntries = try store.listDictionary()
            dictionaryError = nil
        } catch {
            dictionaryEntries = []
            dictionaryError = error.localizedDescription
        }
    }

    private func addDictionaryEntry() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        do {
            let store = try LocalStore(path: settings.storePath)
            try store.upsert(phrase: phrase, replacement: newReplacement)
            newPhrase = ""
            newReplacement = ""
            dictionaryEntries = try store.listDictionary()
            dictionaryError = nil
        } catch {
            dictionaryError = error.localizedDescription
        }
    }

    private func deleteDictionaryEntry(_ phrase: String) {
        do {
            let store = try LocalStore(path: settings.storePath)
            try store.delete(phrase: phrase)
            dictionaryEntries = try store.listDictionary()
            dictionaryError = nil
        } catch {
            dictionaryError = error.localizedDescription
        }
    }

    private func reloadAppProfiles() {
        do {
            let store = try LocalStore(path: settings.storePath)
            appProfiles = try store.listAppProfiles()
            profileError = nil
        } catch {
            appProfiles = []
            profileError = error.localizedDescription
        }
    }

    private func beginAddProfile() {
        editingProfile = nil
        isAddingProfile = true
        draftAppId = ""
        draftDisplayName = ""
        draftTonePreset = .neutral
        draftCustomTone = ""
        draftStripTrailingPeriod = false
        draftSkipFillerRemoval = false
    }

    private func beginEditProfile(_ profile: AppProfile) {
        editingProfile = profile
        isAddingProfile = false
        draftAppId = profile.appId
        draftDisplayName = profile.format.displayName
        draftTonePreset = profile.tonePreset
        draftCustomTone = profile.tonePreset == .custom ? profile.tone : ""
        draftStripTrailingPeriod = profile.format.stripTrailingPeriod
        draftSkipFillerRemoval = profile.format.skipFillerRemoval
    }

    private func cancelProfileEditor() {
        editingProfile = nil
        isAddingProfile = false
    }

    private func addLastDictationAppProfile() {
        guard let bundleId = statusController.lastDictationBundleId, !bundleId.isEmpty else {
            profileError = "还没有听写目标。请先切换到目标 App，按住听写热键一次后再添加。"
            return
        }

        beginAddProfile()
        draftAppId = bundleId
        draftDisplayName = statusController.lastDictationAppName ?? ""
        applySuggestedDefaults(for: bundleId)
        isAddingProfile = true
        profileError = nil
    }

    private func applySuggestedDefaults(for bundleId: String) {
        let id = bundleId.lowercased()
        if id.contains("wechat") || id.contains("xinwechat") || id.contains("slack") || id.contains("dingtalk") || id.contains("telegram") {
            draftTonePreset = .casual
            draftStripTrailingPeriod = true
        } else if id.contains("mail") {
            draftTonePreset = .formal
        } else if id.contains("xcode") || id.contains("cursor") || id.contains("terminal") || id.contains("code") || id.contains("iterm") {
            draftTonePreset = .neutral
            draftSkipFillerRemoval = true
        }
    }

    private func saveProfileDraft() {
        let appId = draftAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appId.isEmpty else { return }

        let tone: String
        switch draftTonePreset {
        case .custom:
            tone = draftCustomTone.trimmingCharacters(in: .whitespacesAndNewlines)
            if tone.isEmpty {
                profileError = "自定义语气不能为空"
                return
            }
        default:
            tone = draftTonePreset.defaultToneText
        }

        var format = AppProfileFormatSettings.empty
        format.displayName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        format.stripTrailingPeriod = draftStripTrailingPeriod
        format.skipFillerRemoval = draftSkipFillerRemoval

        let profile = AppProfile(
            appId: appId,
            tone: tone,
            format: format,
            updatedAtMillis: 0
        )

        do {
            let store = try LocalStore(path: settings.storePath)
            try store.upsertAppProfile(profile)
            appProfiles = try store.listAppProfiles()
            profileError = nil
            cancelProfileEditor()
        } catch {
            profileError = error.localizedDescription
        }
    }

    private func deleteAppProfile(_ appId: String) {
        do {
            let store = try LocalStore(path: settings.storePath)
            try store.deleteAppProfile(appId: appId)
            appProfiles = try store.listAppProfiles()
            profileError = nil
            if editingProfile?.appId == appId {
                cancelProfileEditor()
            }
        } catch {
            profileError = error.localizedDescription
        }
    }
}

// MARK: - Chrome & cards

private enum SettingsChrome {
    static var sidebarFill: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var detailFill: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var cardFill: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var cardStroke: Color {
        Color.primary.opacity(0.08)
    }
}

private struct SettingsSidebarItem: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(pane.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsChrome.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsChrome.cardStroke, lineWidth: 1)
        )
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private enum SettingsStatusTone {
    case ok, warn, error, neutral
}

private struct SettingsStatusBadge: View {
    let text: String
    var tone: SettingsStatusTone = .neutral

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
            .foregroundStyle(foreground)
    }

    private var fill: Color {
        switch tone {
        case .ok: return Color.green.opacity(0.16)
        case .warn: return Color.orange.opacity(0.16)
        case .error: return Color.red.opacity(0.16)
        case .neutral: return Color.secondary.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch tone {
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }
}

private struct SettingsPathField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
    }
}

private struct SettingsPathReadOnly: View {
    let label: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }
}

private struct SettingsLabeledField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct SettingsSecureField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SecureField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct LocalLLMSettingsBlock: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var localLLM: LocalLLMManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow(label: "模型") {
                Text(LocalLLMAssets.modelDisplayName)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRow(label: "状态") {
                SettingsStatusBadge(text: statusText, tone: statusTone)
            }

            if localLLM.isDownloading {
                ProgressView(value: localLLM.overallProgress)
                if !localLLM.byteProgressText.isEmpty {
                    Text(localLLM.byteProgressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !localLLM.downloadSourceLabel.isEmpty {
                    Text("来源：\(localLLM.downloadSourceLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("保守润色（少改动）", isOn: $settings.localLLMConservative)
            SettingsRow(label: "超时（秒）") {
                TextField("", value: $settings.localLLMTimeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
            }

            if case .failed(let message) = localLLM.phase {
                Button("重试下载") {
                    LocalLLMManager.shared.forceRestartDownload()
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if localLLM.isDownloading {
                Button("取消并换源重试") {
                    LocalLLMManager.shared.forceRestartDownload()
                }
            } else if !LocalLLMAssets.isReady {
                Button("开始下载") {
                    LocalLLMManager.shared.forceRestartDownload()
                }
            }

            SettingsPathReadOnly(label: "本地路径", path: LocalLLMAssets.rootDirectory.path)
        }
    }

    private var statusText: String {
        switch localLLM.phase {
        case .idle:
            return LocalLLMAssets.isReady ? "已就绪" : "未下载"
        case .downloadingCLI:
            return "下载运行时 \(Int(localLLM.fileProgress * 100))%"
        case .downloadingModel:
            let bytes = localLLM.byteProgressText
            if bytes.isEmpty {
                return "下载模型 \(Int(localLLM.overallProgress * 100))%"
            }
            return "下载模型 \(bytes)"
        case .ready:
            return "已就绪"
        case .failed:
            return "失败"
        }
    }

    private var statusTone: SettingsStatusTone {
        switch localLLM.phase {
        case .ready: return .ok
        case .failed: return .error
        case .downloadingCLI, .downloadingModel: return .warn
        case .idle: return LocalLLMAssets.isReady ? .ok : .neutral
        }
    }
}

/// Click to capture the next key press as the push-to-talk hotkey.
private struct HotkeyCaptureButton: View {
    @Binding var keyCode: Int
    /// `true` while capturing; `false` when finished or cancelled.
    var onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var errorText: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(isRecording ? "按下新热键…（Esc 取消）" : "录制自定义热键…") {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .orange : .accentColor)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        errorText = nil
        isRecording = true
        onRecordingChange(true)
        stopMonitor()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleCapture(event)
        }
    }

    private func stopRecording() {
        guard isRecording || monitor != nil else { return }
        isRecording = false
        stopMonitor()
        onRecordingChange(false)
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleCapture(_ event: NSEvent) -> NSEvent? {
        let code = UInt16(event.keyCode)

        if event.type == .keyDown, Int(code) == kVK_Escape {
            DispatchQueue.main.async {
                self.stopRecording()
            }
            return nil
        }

        if event.type == .flagsChanged {
            guard DictationHotkey(keyCode: code).isModifier else {
                return event
            }
            let down: Bool
            switch code {
            case 58, 61: down = event.modifierFlags.contains(.option)
            case 59, 62: down = event.modifierFlags.contains(.control)
            case 56, 60: down = event.modifierFlags.contains(.shift)
            case 63: down = event.modifierFlags.contains(.function)
            default: down = false
            }
            guard down else { return nil }
        } else if event.type != .keyDown {
            return event
        }

        guard DictationHotkey.isAllowed(code) else {
            DispatchQueue.main.async {
                self.errorText = "不能使用 Esc 或 Command，请换一个键"
            }
            return nil
        }

        DispatchQueue.main.async {
            self.keyCode = Int(code)
            self.errorText = nil
            self.stopRecording()
        }
        return nil
    }
}
