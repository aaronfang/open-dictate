import AppKit
import AVFoundation
import SwiftUI

@main
struct OpenDictateMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let status = StatusController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar agent: keep running with no visible windows.
        NSApp.setActivationPolicy(.accessory)
        migrateWhisperDefaultsIfNeeded()
        Permissions.requestOnLaunch()
        status.start(menuTarget: self)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openSettings(_:)),
            name: Notification.Name("OpenDictateOpenSettings"),
            object: nil
        )

        if let probe = ProcessInfo.processInfo.environment["OPEN_DICTATE_PROBE_WAV"], !probe.isEmpty {
            Task {
                // Wait until model is loaded, then transcribe the probe file.
                for _ in 0..<300 {
                    if StatusController.shared.transcriberIsLoaded {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                await StatusController.shared.probeTranscribe(wavPath: probe)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func migrateWhisperDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let brewCLI = "/opt/homebrew/bin/whisper-cli"

        if FileManager.default.isExecutableFile(atPath: brewCLI) {
            let binary = defaults.string(forKey: "whisperBinary") ?? ""
            if binary.isEmpty || binary == "whisper-cli" || !FileManager.default.isExecutableFile(atPath: NSString(string: binary).expandingTildeInPath) {
                defaults.set(brewCLI, forKey: "whisperBinary")
            }
        }

        let repoModel = "/Users/aaronfang/Documents/github/open-dictate/models/ggml-base.bin"
        if FileManager.default.fileExists(atPath: repoModel) {
            let model = defaults.string(forKey: "whisperModelPath") ?? ""
            let expanded = NSString(string: model).expandingTildeInPath
            if model.isEmpty || model.contains("base.en") || !FileManager.default.fileExists(atPath: expanded) {
                defaults.set(repoModel, forKey: "whisperModelPath")
            }
        }

        if defaults.string(forKey: "whisperLanguage") == nil || defaults.string(forKey: "whisperLanguage") == "auto" {
            defaults.set("zh", forKey: "whisperLanguage")
        }

        let senseVoiceDir = SenseVoiceConfig.defaultModelsDirectory
        let preprocessor = "\(senseVoiceDir)/SenseVoicePreprocessor.mlmodelc"
        let encoder = "\(senseVoiceDir)/SenseVoiceSmall_int8.mlmodelc"
        if FileManager.default.fileExists(atPath: preprocessor),
           FileManager.default.fileExists(atPath: encoder) {
            defaults.set(STTEngine.senseVoice.rawValue, forKey: "sttEngine")
            defaults.set(senseVoiceDir, forKey: "senseVoiceModelsPath")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        status.stop()
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}

struct SettingsView: View {
    @StateObject private var settings = AppSettings()
    @ObservedObject var statusController: StatusController
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
        ScrollView {
            Form {
            Section("权限") {
                LabeledContent("麦克风") {
                    Text(Permissions.isMicrophoneGranted ? "已授权" : "未授权")
                        .foregroundStyle(Permissions.isMicrophoneGranted ? .green : .orange)
                }
                LabeledContent("辅助功能") {
                    Text(Permissions.isAccessibilityGranted ? "已授权" : "未授权")
                        .foregroundStyle(Permissions.isAccessibilityGranted ? .green : .orange)
                }
                Text("通过 swift run 运行时，系统设置中显示为 OpenDictateMac，路径：")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(Permissions.executablePath)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("打开麦克风设置") { Permissions.openMicrophoneSettings() }
                    Button("打开辅助功能设置") { Permissions.openAccessibilitySettings() }
                }
            }

            Section("热键") {
                LabeledContent("默认热键") {
                    Text("右 Option（按住说话）")
                }
                LabeledContent("热键监听") {
                    Text(statusController.hotkeyActive ? "已启动" : "未启动（请检查辅助功能授权）")
                        .foregroundStyle(statusController.hotkeyActive ? .green : .orange)
                }
                Text("提示：全局热键与文本注入需要在“隐私与安全性 → 辅助功能(Accessibility)”中授权本 App。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("双屏用户：若菜单栏图标只出现在某一块屏幕，请在“系统设置 → 桌面与程序坞”中开启“显示器具有单独的空间”，或为菜单栏指定主显示器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("语音识别") {
                Picker("识别引擎", selection: $settings.sttEngineRaw) {
                    ForEach(STTEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if settings.sttEngine == .senseVoice {
                    TextField("SenseVoice 模型目录", text: $settings.senseVoiceModelsPath)
                    Picker("识别语言", selection: $settings.senseVoiceLanguage) {
                        Text("中文（推荐）").tag("zh")
                        Text("自动").tag("auto")
                        Text("英语").tag("en")
                        Text("粤语").tag("yue")
                        Text("日语").tag("ja")
                        Text("韩语").tag("ko")
                    }
                    Toggle("标点与数字归一化（ITN）", isOn: $settings.senseVoiceEnableITN)
                    Text("开启后由 SenseVoice 输出逗号、句号等标点；关闭则为纯文本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("使用 INT8 模型（更小，推荐）", isOn: $settings.senseVoiceUseInt8)
                    Toggle("使用 FP32 编码器（无 ANE 时）", isOn: $settings.senseVoiceUseFp32)
                    LabeledContent("模型状态") {
                        Text(settings.senseVoiceModelsReady ? "已就绪" : "未下载")
                            .foregroundStyle(settings.senseVoiceModelsReady ? .green : .orange)
                    }
                    Text("首次使用请运行：./scripts/download_sensevoice_models.sh")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("听写全程本地 CoreML，不需要网络。首次启动可能编译 Neural Engine（仅一次）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("whisper.cpp 可执行文件", text: $settings.whisperBinary)
                    TextField("模型路径（ggml *.bin）", text: $settings.whisperModelPath)
                    TextField("语言（auto / zh / en）", text: $settings.whisperLanguage)
                }
            }

            Section("文本润色") {
                Toggle("规则后处理（去口癖 / 空白归一化）", isOn: $settings.enableRulesPostprocess)
                Text("默认开启。流水线：词典 → 规则 → 可选 LLM → App 格式。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("DeepSeek 云端润色（仅发送文本）", isOn: $settings.enableDeepSeekPostprocess)
                if settings.enableDeepSeekPostprocess {
                    SecureField("API Key", text: $settings.deepSeekApiKey)
                    TextField("Base URL", text: $settings.deepSeekBaseURL)
                    Picker("模型", selection: $settings.deepSeekModel) {
                        Text("deepseek-v4-flash（推荐，更快）").tag("deepseek-v4-flash")
                        Text("deepseek-v4-pro").tag("deepseek-v4-pro")
                    }
                    HStack {
                        Text("超时（秒）")
                        TextField("", value: $settings.deepSeekTimeoutSeconds, format: .number)
                            .frame(width: 56)
                    }
                    Toggle("保守润色（少改动）", isOn: $settings.deepSeekConservative)
                    LabeledContent("出网类型") {
                        Text("文本（识别结果）")
                            .foregroundStyle(.orange)
                    }
                    Text("默认关闭。开启后仅把转写文本发往 DeepSeek；失败或超时会回退到规则结果并照常上屏。Key 存于本机 UserDefaults。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !settings.deepSeekConfigured {
                        Text("请填写 API Key 后才会真正请求。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("数据存储") {
                TextField("SQLite 存储路径", text: $settings.storePath)
                Text("默认仅本地存储词典与画像，不做任何遥测。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("词典") {
                if let dictionaryError {
                    Text(dictionaryError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if dictionaryEntries.isEmpty {
                    Text("暂无词条。添加后，听写结果中的原文会被替换为对应写法。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dictionaryEntries) { entry in
                        HStack {
                            Text(entry.phrase)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text(entry.replacement)
                            Spacer()
                            Button(role: .destructive) {
                                deleteDictionaryEntry(entry.phrase)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    TextField("原文", text: $newPhrase)
                    TextField("替换为", text: $newReplacement)
                    Button("添加") { addDictionaryEntry() }
                        .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("按应用的写法（App 画像）") {
                Text("按目标 App 的 Bundle ID 套用语气与格式。开启 DeepSeek 时语气会写入 prompt；格式规则在 LLM 之后仍会生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let profileError {
                    Text(profileError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if appProfiles.isEmpty {
                    Text("暂无画像。可添加微信口语、邮件正式、IDE 少改符号等配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appProfiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile.resolvedDisplayName)
                                    .fontWeight(.medium)
                                Spacer()
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
                            Text(profileFormatSummary(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if isAddingProfile || editingProfile != nil {
                    profileEditor
                } else {
                    HStack {
                        Button("添加最近听写的 App") { addLastDictationAppProfile() }
                        Button("手动添加") { beginAddProfile() }
                    }
                    Text("先在目标 App 里按住 Option 听写一次，再点「添加最近听写的 App」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { reloadAllStoreData() }
        .onChange(of: settings.storePath) { _, _ in reloadAllStoreData() }
    }

    @ViewBuilder
    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editingProfile == nil ? "新建画像" : "编辑画像")
                .fontWeight(.semibold)
            TextField("Bundle ID", text: $draftAppId)
                .disabled(editingProfile != nil)
            TextField("显示名称（可选）", text: $draftDisplayName)
            Picker("语气", selection: $draftTonePreset) {
                ForEach(AppTonePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            if draftTonePreset == .custom {
                TextField("自定义语气（将用于 LLM）", text: $draftCustomTone)
            } else {
                Text(draftTonePreset.defaultToneText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("聊天场景：去掉句末句号", isOn: $draftStripTrailingPeriod)
            Toggle("开发工具：保留口癖、少做规则清理", isOn: $draftSkipFillerRemoval)
            HStack {
                Button("保存") { saveProfileDraft() }
                    .disabled(draftAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消") { cancelProfileEditor() }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

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
            profileError = "还没有听写目标。请先切换到目标 App，按住 Option 听写一次后再添加。"
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

final class StatusController: NSObject, ObservableObject {
    static let shared = StatusController()

    private var item: NSStatusItem?
    private var statusMenu: NSMenu?
    private var modelStatusMenuItem: NSMenuItem?
    private var loadingSpinner: NSProgressIndicator?
    private let hotkey = HotkeyMonitor(hotkey: .init(keyCode: 61))
    private let recorder = AudioRecorder()
    private let transcriber = SpeechTranscriber()
    private let settings = AppSettings()
    private let hud = HudWindow()
    private let injector = TextInjector()

    @Published var hotkeyActive = false
    private(set) var lastDictationBundleId: String?
    private(set) var lastDictationAppName: String?

    var transcriberIsLoaded: Bool { transcriber.isSenseVoiceLoaded }

    private enum ModelUIState {
        case ready
        case warming
        case loading
        case failed
        case missingModels
        case idle
    }

    func probeTranscribe(wavPath: String) async {
        let url = URL(fileURLWithPath: wavPath)
        do {
            let raw = try await transcriber.transcribe(wavURL: url, settings: settings)
            let processed = await TextIntelligence.process(raw, settings: settings)
            NSLog("PROBE result raw=\(raw) final=\(processed.text) llm=\(processed.llmApplied)")
        } catch {
            NSLog("PROBE failed: \(error.localizedDescription)")
        }
    }

    func start(menuTarget: NSObject) {
        installStatusItem(menuTarget: menuTarget)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshModelStatusUI),
            name: .senseVoiceLoadStarted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshModelStatusUI),
            name: .senseVoiceLoaded,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshModelStatusUI),
            name: .senseVoiceWarmedUp,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshModelStatusUI),
            name: .senseVoiceLoadFailed,
            object: nil
        )

        hotkey.onHotkeyDown = { [weak self] in
            guard let self else { return }
            NSLog("Recording hotkey down")
            self.injector.rememberTarget()
            self.lastDictationBundleId = self.injector.targetBundleId
            self.lastDictationAppName = self.injector.targetAppName
            // Kick model load as early as possible (parallel with recording).
            if self.settings.sttEngine == .senseVoice, !self.transcriber.isSenseVoiceLoaded {
                self.transcriber.preload(settings: self.settings)
                self.refreshStatusAppearance()
                self.hud.show(text: "正在录音（模型加载中）…")
            } else {
                self.hud.show(text: "正在录音…")
            }
            do {
                _ = try self.recorder.startRecording()
            } catch {
                NSLog("startRecording error: \(error)")
                self.hud.show(text: "录音失败：\((error as NSError).localizedDescription)")
            }
        }
        hotkey.onHotkeyUp = { [weak self] in
            guard let self else { return }
            NSLog("Recording hotkey up")
            self.recorder.stopRecording()
            self.hud.hide()

            guard let wavURL = self.recorder.lastRecordingURL else {
                self.hud.show(text: "未找到录音文件")
                return
            }

            Task {
                let statusText: String
                if self.settings.sttEngine == .senseVoice {
                    if !self.transcriber.isSenseVoiceLoaded {
                        statusText = "模型加载中…"
                    } else if !self.transcriber.isSenseVoiceWarmedUp {
                        statusText = "正在识别（首次可能较慢）…"
                    } else {
                        statusText = "正在识别…"
                    }
                } else {
                    statusText = "正在识别…"
                }
                await MainActor.run {
                    self.hud.show(text: statusText)
                }
                do {
                    let raw = try await self.transcriber.transcribe(wavURL: wavURL, settings: self.settings)
                    let appId = self.injector.targetBundleId
                    if self.settings.enableDeepSeekPostprocess, self.settings.deepSeekConfigured {
                        await MainActor.run {
                            self.hud.show(text: "正在润色…")
                        }
                    }
                    let processed = await TextIntelligence.process(raw, settings: self.settings, appId: appId)
                    NSLog(
                        "TextIntelligence app=%@ tone=%@ profile=%@ llm=%@",
                        processed.appId ?? "nil",
                        processed.tone ?? "none",
                        processed.profileApplied ? "yes" : "no",
                        processed.llmApplied ? "yes" : "no"
                    )
                    let text = processed.text
                    await MainActor.run {
                        self.hud.hide()
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return
                        }
                        self.injector.insert(text: text)
                    }
                } catch let error as SenseVoiceCoreMLError {
                    switch error {
                    case .noSpeech, .emptyResult:
                        // Silence / punctuation-only: no paste, no error toast.
                        NSLog("transcribe soft-skip: \(error.localizedDescription)")
                        await MainActor.run { self.hud.hide() }
                    default:
                        NSLog("transcribe error: \(error.localizedDescription)")
                        await MainActor.run {
                            self.hud.show(text: "识别失败：\(error.localizedDescription)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                self.hud.hide()
                            }
                        }
                    }
                } catch {
                    NSLog("transcribe error: \(error.localizedDescription)")
                    await MainActor.run {
                        self.hud.show(text: "识别失败：\(error.localizedDescription)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            self.hud.hide()
                        }
                    }
                }
            }
        }

        hotkey.start()
        hotkeyActive = hotkey.isActive
        // Auto-load SenseVoice at launch so the first dictation isn't blocked.
        transcriber.preload(settings: settings)
        refreshStatusAppearance()
    }

    func stop() {
        hotkey.stop()
        clearLoadingSpinner()
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        statusMenu = nil
        modelStatusMenuItem = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func installStatusItem(menuTarget: NSObject) {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        clearLoadingSpinner()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let modelStatus = NSMenuItem(title: "模型：…", action: nil, keyEquivalent: "")
        modelStatus.isEnabled = false
        menu.addItem(modelStatus)
        modelStatusMenuItem = modelStatus
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Open Settings…",
            action: #selector(AppDelegate.openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = menuTarget
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        item.menu = menu
        self.item = item
        self.statusMenu = menu
        refreshStatusAppearance()
    }

    @objc private func screenParametersChanged() {
        guard let menuTarget = NSApp.delegate as? NSObject else { return }
        installStatusItem(menuTarget: menuTarget)
    }

    @objc private func refreshModelStatusUI() {
        refreshStatusAppearance()
    }

    private func modelUIState() -> ModelUIState {
        guard settings.sttEngine == .senseVoice else { return .idle }
        guard settings.senseVoiceModelsReady else { return .missingModels }
        if transcriber.isSenseVoiceWarmedUp { return .ready }
        if transcriber.isSenseVoiceLoaded { return .warming }
        if transcriber.didSenseVoiceLoadFail { return .failed }
        return .loading
    }

    private func refreshStatusAppearance() {
        guard let button = item?.button else { return }
        let state = modelUIState()
        button.toolTip = statusToolTip(for: state)
        modelStatusMenuItem?.title = modelStatusTitle(for: state)

        switch state {
        case .loading:
            showLoadingSpinner(in: button)
        case .warming:
            clearLoadingSpinner()
            setStatusSymbol("mic", on: button)
        case .ready, .idle:
            clearLoadingSpinner()
            setStatusSymbol("mic.fill", on: button)
        case .missingModels, .failed:
            clearLoadingSpinner()
            setStatusSymbol("mic.slash", on: button)
        }
    }

    private func setStatusSymbol(_ name: String, on button: NSStatusBarButton) {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "OpenDictate") {
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
    }

    private func showLoadingSpinner(in button: NSStatusBarButton) {
        if loadingSpinner == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            loadingSpinner = spinner
        }
        button.image = nil
        button.title = ""
        // Keep a stable click target while the spinner is showing.
        item?.length = 28
        loadingSpinner?.startAnimation(nil)
    }

    private func clearLoadingSpinner() {
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.removeFromSuperview()
        loadingSpinner = nil
        item?.length = NSStatusItem.variableLength
    }

    private func modelStatusTitle(for state: ModelUIState) -> String {
        switch state {
        case .loading: return "模型：加载中…"
        case .warming: return "模型：已加载（预热中）"
        case .ready: return "模型：就绪"
        case .failed: return "模型：加载失败"
        case .missingModels: return "模型：未下载"
        case .idle: return "引擎：whisper.cpp"
        }
    }

    private func statusToolTip(for state: ModelUIState) -> String {
        switch state {
        case .loading: return "OpenDictate（模型加载中…）"
        case .warming: return "OpenDictate（已加载，后台预热中…）"
        case .ready: return "OpenDictate（就绪）"
        case .failed: return "OpenDictate（模型加载失败）"
        case .missingModels: return "OpenDictate（SenseVoice 模型未下载）"
        case .idle: return "OpenDictate"
        }
    }
}
