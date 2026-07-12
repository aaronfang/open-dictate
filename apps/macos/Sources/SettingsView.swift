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
        case .storage: return "本地库路径与听写历史"
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

    @State private var historyEntries: [DictationHistoryEntry] = []
    @State private var historyCount = 0
    @State private var historyError: String?
    @State private var confirmClearHistory = false

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
            footer: "\(settings.dictationTriggerMode.hint)。支持单键或组合键（如 ⌃空格、⌃⇧D）。组合键在「按住说话」下：按下主键开始后，可松开主键、继续按住修饰键说话，松修饰键结束。录音/识别中可按 Esc 取消。听写若用单独 Option，Ask 请勿用 Option+…（会抢触发）。"
        ) {
            SettingsRow(label: "当前热键") {
                Text(settings.dictationHotkey.settingsLabel(mode: settings.dictationTriggerMode))
                    .foregroundStyle(.primary)
            }
            SettingsRow(label: "热键监听") {
                SettingsStatusBadge(
                    text: statusController.hotkeyActive ? "已启动" : "未启动",
                    tone: statusController.hotkeyActive ? .ok : .warn
                )
            }

            Picker("触发方式", selection: triggerModeBinding) {
                ForEach(DictationTriggerMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            Picker("常用热键", selection: hotkeyPresetBinding) {
                ForEach(DictationHotkey.presets) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
                if !DictationHotkey.presets.contains(settings.dictationHotkey) {
                    Text(settings.dictationHotkey.displayName)
                        .tag(settings.dictationHotkey.id)
                }
            }

            HotkeyCaptureButton(hotkey: dictationHotkeyBinding) { recording in
                if recording {
                    statusController.pauseHotkeyForCapture()
                } else {
                    resolveAskHotkeyConflictIfNeeded()
                    statusController.resumeHotkeyAfterCapture()
                }
            }

            if settings.dictationHotkey != .default {
                Button("恢复默认（右 Option）") {
                    settings.dictationHotkey = .default
                    statusController.applyDictationHotkeyFromSettings()
                }
                .buttonStyle(.borderless)
            }
        }

        SettingsCard(
            title: "Ask AI",
            footer: "先选中文本（可编辑或只读均可）。取不到选区时会试 Cmd+C；仍失败会提示。开启「剪贴板兜底」时，可用你事先 Cmd+C 的内容。需要开启本地或 DeepSeek 润色。触发方式与听写相同。"
        ) {
            Toggle("启用 Ask AI", isOn: askEnabledBinding)

            if settings.enableAskAI {
                Toggle("选区失败时使用剪贴板", isOn: $settings.askAllowClipboardFallback)
                Text("默认关闭。开启后，取不到选区时会用剪贴板里已有文字当选区（易把语音指令误当成听写上屏）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsRow(label: "当前热键") {
                    Text(settings.askAIHotkey.displayName)
                        .foregroundStyle(.primary)
                }

                Picker("常用热键", selection: askHotkeyPresetBinding) {
                    ForEach(DictationHotkey.presets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                    if !DictationHotkey.presets.contains(settings.askAIHotkey) {
                        Text(settings.askAIHotkey.displayName)
                            .tag(settings.askAIHotkey.id)
                    }
                }

                HotkeyCaptureButton(hotkey: askHotkeyBinding) { recording in
                    if recording {
                        statusController.pauseHotkeyForCapture()
                    } else {
                        resolveAskHotkeyConflictIfNeeded()
                        statusController.resumeHotkeyAfterCapture()
                    }
                }

                if settings.askAIHotkey == settings.dictationHotkey {
                    Text("Ask 热键与听写热键相同，请更换其中一个。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.askAIHotkey != .defaultAsk {
                    Button("恢复默认（F6）") {
                        settings.askAIHotkey = .defaultAsk
                        statusController.applyAskHotkeyFromSettings()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var dictationHotkeyBinding: Binding<DictationHotkey> {
        Binding(
            get: { settings.dictationHotkey },
            set: { newValue in
                settings.dictationHotkey = newValue
                resolveAskHotkeyConflictIfNeeded()
                statusController.applyDictationHotkeyFromSettings()
            }
        )
    }

    private var askHotkeyBinding: Binding<DictationHotkey> {
        Binding(
            get: { settings.askAIHotkey },
            set: { newValue in
                settings.askAIHotkey = newValue
                resolveAskHotkeyConflictIfNeeded()
                statusController.applyAskHotkeyFromSettings()
            }
        )
    }

    private var triggerModeBinding: Binding<String> {
        Binding(
            get: { settings.dictationTriggerModeRaw },
            set: { newValue in
                settings.dictationTriggerModeRaw = newValue
                statusController.applyDictationHotkeyFromSettings()
            }
        )
    }

    private var hotkeyPresetBinding: Binding<String> {
        Binding(
            get: { settings.dictationHotkey.id },
            set: { newValue in
                if let preset = DictationHotkey.presets.first(where: { $0.id == newValue }) {
                    settings.dictationHotkey = preset
                } else if let parsed = Self.parseHotkeyId(newValue) {
                    settings.dictationHotkey = parsed
                }
                resolveAskHotkeyConflictIfNeeded()
                statusController.applyDictationHotkeyFromSettings()
            }
        )
    }

    private var askEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enableAskAI },
            set: { newValue in
                settings.enableAskAI = newValue
                statusController.applyAskHotkeyFromSettings()
            }
        )
    }

    private var askHotkeyPresetBinding: Binding<String> {
        Binding(
            get: { settings.askAIHotkey.id },
            set: { newValue in
                if let preset = DictationHotkey.presets.first(where: { $0.id == newValue }) {
                    settings.askAIHotkey = preset
                } else if let parsed = Self.parseHotkeyId(newValue) {
                    settings.askAIHotkey = parsed
                }
                resolveAskHotkeyConflictIfNeeded()
                statusController.applyAskHotkeyFromSettings()
            }
        )
    }

    private func resolveAskHotkeyConflictIfNeeded() {
        if settings.askAIHotkey == settings.dictationHotkey {
            let fallback = DictationHotkey.defaultAsk
            settings.askAIHotkey = settings.dictationHotkey == fallback
                ? (DictationHotkey.presets.first(where: { $0 != settings.dictationHotkey }) ?? DictationHotkey(keyCode: 96))
                : fallback
        }
    }

    private static func parseHotkeyId(_ id: String) -> DictationHotkey? {
        let parts = id.split(separator: "|")
        guard parts.count == 2,
              let code = UInt16(parts[0]),
              let mods = Int(parts[1]) else { return nil }
        return DictationHotkey(keyCode: code, modifiers: HotkeyModifierFlags(rawValue: mods))
    }

    @ViewBuilder
    private var recognitionPane: some View {
        SettingsCard(title: "识别引擎", footer: "推荐 SenseVoice（本地 CoreML）。whisper.cpp 适合已有 ggml 模型的场景。火山引擎为云端 ASR，录音会出网。") {
            Picker("", selection: $settings.sttEngineRaw) {
                ForEach(STTEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        SettingsCard(
            title: "录音前端",
            footer: "Voice Processing 默认关闭（开启时录音期间会压低其他声音）。嘈杂策略默认关闭：加强降噪会强制启用 VP；优先 Whisper 仅在已配置 whisper.cpp 时覆盖默认引擎。"
        ) {
            Toggle("Voice Processing（降噪 / AGC）", isOn: $settings.enableVoiceProcessing)
            Toggle("点按模式：尾静音自动结束", isOn: $settings.enableSilenceAutoStop)
            Picker("嘈杂场景策略", selection: $settings.noisySceneStrategyRaw) {
                ForEach(NoisySceneStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy.rawValue)
                }
            }
        }

        if settings.sttEngine == .senseVoice {
            SettingsCard(title: "常用选项", footer: "开启 ITN 后输出逗号、句号等标点；关闭则为纯文本。听写全程本地，不需要网络。简繁转换在识别与润色之后统一执行。") {
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
                SettingsRow(label: "汉字字形") {
                    Picker("", selection: $settings.chineseScriptRaw) {
                        ForEach(ChineseScriptPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref.rawValue)
                        }
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
        } else if settings.sttEngine == .whisper {
            SettingsCard(title: "whisper.cpp") {
                SettingsPathField(label: "可执行文件", text: $settings.whisperBinary)
                SettingsPathField(label: "模型路径（ggml *.bin）", text: $settings.whisperModelPath)
                SettingsLabeledField(label: "语言", placeholder: "auto / zh / en", text: $settings.whisperLanguage)
                SettingsRow(label: "汉字字形") {
                    Picker("", selection: $settings.chineseScriptRaw) {
                        ForEach(ChineseScriptPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
        } else if settings.sttEngine == .volcengine {
            SettingsCard(
                title: "火山引擎 ASR",
                footer: "使用豆包「录音文件极速版」HTTP。新版控制台填 API Key 即可；旧版填 App Key + Access Key。需在控制台开通 volc.bigasr.auc_turbo。Key 存于本机 UserDefaults。"
            ) {
                SettingsSecureField(label: "API Key（新版优先）", text: $settings.volcengineApiKey)
                SettingsSecureField(label: "App Key", text: $settings.volcengineAppKey)
                SettingsSecureField(label: "Access Key", text: $settings.volcengineAccessKey)
                SettingsRow(label: "超时（秒）") {
                    TextField("", value: $settings.volcengineTimeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
                SettingsRow(label: "出网类型") {
                    SettingsStatusBadge(text: "音频（整段录音）", tone: .warn)
                }
                SettingsRow(label: "汉字字形") {
                    Picker("", selection: $settings.chineseScriptRaw) {
                        ForEach(ChineseScriptPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                if !settings.volcengineConfigured {
                    Text("请填写 API Key，或同时填写 App Key 与 Access Key。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "高级") {
                SettingsPathField(label: "Endpoint", text: $settings.volcengineEndpoint)
                SettingsLabeledField(
                    label: "Resource Id",
                    placeholder: "volc.bigasr.auc_turbo",
                    text: $settings.volcengineResourceId
                )
            }
        }
    }

    @ViewBuilder
    private var polishPane: some View {
        SettingsCard(
            title: "规则后处理",
            footer: "默认开启。含去口癖、空白归一化与连续重复折叠。开启 LLM 时由模型语义判断改口（不再关键词截断）；关闭 LLM 时仍用关键词兜底。流水线：词典 → 规则 → 可选 LLM → App 格式。"
        ) {
            Toggle("去口癖 / 去重复（规则）", isOn: $settings.enableRulesPostprocess)
        }

        SettingsCard(title: "LLM 润色", footer: "关闭时仅用规则与词典。开启后由模型语义整理与改口；失败则回退规则结果。Ask AI 也依赖此项。本地模型不出网；DeepSeek 仅发送文本。") {
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
            SettingsCard(title: "DeepSeek", footer: "失败或超时会回退到规则结果并照常上屏。Key 存于本机 UserDefaults。默认开启思考模式；润色/Ask 分别限制 max_tokens 为 1024 / 2048。") {
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
        SettingsCard(
            title: "自动学习",
            footer: "上屏后若你在输入框里改了刚粘贴的内容，会按词拆成多条短替换记入词典（至少 2 字，避免单字误伤）。仅读焦点文本，不出网；可随时关闭。"
        ) {
            Toggle("纠错后自动记入词典", isOn: $settings.enableAutoDictionaryLearn)
        }

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
        SettingsCard(title: "本地数据库", footer: "默认仅本地存储词典、画像与可选历史，不做任何遥测。修改路径后会重新加载。") {
            SettingsPathField(label: "SQLite 存储路径", text: $settings.storePath)
        }

        SettingsCard(
            title: "听写历史",
            footer: "默认关闭。开启后仅将最终上屏文本存于本机 SQLite，可随时清除。不存音频。"
        ) {
            Toggle("保存听写历史", isOn: $settings.enableDictationHistory)
                .onChange(of: settings.enableDictationHistory) { _, enabled in
                    if enabled { reloadHistory() }
                }

            if settings.enableDictationHistory {
                SettingsRow(label: "保留时长") {
                    Picker("", selection: $settings.historyRetentionDays) {
                        Text("7 天").tag(7)
                        Text("14 天").tag(14)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("直到手动清除").tag(0)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    .onChange(of: settings.historyRetentionDays) { _, _ in
                        reloadHistory()
                    }
                }

                if let historyError {
                    Text(historyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(historyCount == 0 ? "暂无记录" : "共 \(historyCount) 条")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除全部", role: .destructive) {
                        confirmClearHistory = true
                    }
                    .disabled(historyCount == 0)
                    .confirmationDialog("清除全部听写历史？", isPresented: $confirmClearHistory) {
                        Button("清除", role: .destructive) { clearAllHistory() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("此操作不可撤销。词典与画像不受影响。")
                    }
                }

                if !historyEntries.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(historyEntries.enumerated()), id: \.element.id) { index, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(historyTimestamp(entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(historySourceLabel(entry.source))
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        deleteHistoryEntry(entry.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Text(entry.finalText)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                if shouldShowHistoryRaw(entry) {
                                    Text("识别原文：\(entry.rawText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                                if let appId = entry.appId, !appId.isEmpty {
                                    Text(appId)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 8)
                            if index < historyEntries.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
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
        reloadHistory()
    }

    private func reloadHistory() {
        do {
            let store = try LocalStore(path: settings.storePath)
            if settings.historyRetentionDays > 0 {
                try store.pruneHistory(retentionDays: settings.historyRetentionDays)
            }
            historyEntries = try store.listHistory(limit: 80)
            historyCount = try store.historyCount()
            historyError = nil
        } catch {
            historyEntries = []
            historyCount = 0
            historyError = error.localizedDescription
        }
    }

    private func deleteHistoryEntry(_ id: Int64) {
        do {
            let store = try LocalStore(path: settings.storePath)
            try store.deleteHistory(id: id)
            reloadHistory()
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func clearAllHistory() {
        do {
            let store = try LocalStore(path: settings.storePath)
            try store.clearHistory()
            reloadHistory()
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func historyTimestamp(_ entry: DictationHistoryEntry) -> String {
        entry.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func historySourceLabel(_ source: String) -> String {
        switch source {
        case "ask": return "Ask"
        case "dictate": return "听写"
        default: return source
        }
    }

    /// Show STT raw only when polish changed substance (not just 就→， / spacing).
    private func shouldShowHistoryRaw(_ entry: DictationHistoryEntry) -> Bool {
        let raw = entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != final else { return false }

        let rawCore = String(raw.filter { !$0.isWhitespace && !$0.isPunctuation })
        let finalCore = String(final.filter { !$0.isWhitespace && !$0.isPunctuation })
        if rawCore == finalCore { return false }

        // Ignore tiny particle tweaks (e.g. drop one「就/了」).
        return contentDiffUnits(rawCore, finalCore) >= 2
    }

    private func contentDiffUnits(_ a: String, _ b: String) -> Int {
        let ac = Array(a)
        let bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }
        var prev = Array(0...bc.count)
        var cur = Array(repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            cur[0] = i
            for j in 1...bc.count {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[bc.count]
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

/// Click to capture the next key / chord as the hotkey.
private struct HotkeyCaptureButton: View {
    @Binding var hotkey: DictationHotkey
    /// `true` while capturing; `false` when finished or cancelled.
    var onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var errorText: String?
    @State private var monitor: Any?
    @State private var pendingSoloModifier: UInt16?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(isRecording ? "按下新热键或组合键…（Esc 取消）" : "录制自定义热键…") {
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
        pendingSoloModifier = nil
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
        pendingSoloModifier = nil
        stopMonitor()
        onRecordingChange(false)
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func commit(_ captured: DictationHotkey) {
        DispatchQueue.main.async {
            self.hotkey = captured
            self.errorText = nil
            self.pendingSoloModifier = nil
            self.stopRecording()
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
            let isMod = DictationHotkey(keyCode: code).isModifierKey
            guard isMod else { return event }

            let down: Bool
            switch code {
            case 58, 61: down = event.modifierFlags.contains(.option)
            case 59, 62: down = event.modifierFlags.contains(.control)
            case 56, 60: down = event.modifierFlags.contains(.shift)
            case 55, 54: down = event.modifierFlags.contains(.command)
            case 63: down = event.modifierFlags.contains(.function)
            default: down = false
            }

            if down {
                // Wait for either a chord key or release of this lone modifier.
                pendingSoloModifier = code
                return nil
            }

            // Modifier released: if nothing else was pressed, accept lone modifier
            // (except Command — reserved for system paste).
            if pendingSoloModifier == code {
                pendingSoloModifier = nil
                if code == UInt16(kVK_Command) || code == UInt16(kVK_RightCommand) {
                    DispatchQueue.main.async {
                        self.errorText = "不能单独使用 Command，请换一个键或组合键"
                    }
                    return nil
                }
                guard DictationHotkey.isAllowedPrimaryKey(code) else {
                    DispatchQueue.main.async {
                        self.errorText = "不能使用 Esc 或 Command 作为主键"
                    }
                    return nil
                }
                commit(DictationHotkey(keyCode: code))
            }
            return nil
        }

        guard event.type == .keyDown else { return event }
        // Chord or plain key: modifiers from the event + this key.
        pendingSoloModifier = nil
        let mods = HotkeyModifierFlags.from(nsFlags: event.modifierFlags)
        guard DictationHotkey.isAllowedPrimaryKey(code) else {
            DispatchQueue.main.async {
                self.errorText = "不能使用 Esc 或 Command 作为主键，可用 ⌘ 作修饰键"
            }
            return nil
        }
        // Lone modifier keys shouldn't arrive as keyDown on macOS typically.
        if DictationHotkey(keyCode: code).isModifierKey, mods.isEmpty {
            return nil
        }
        commit(DictationHotkey(keyCode: code, modifiers: mods))
        return nil
    }
}
