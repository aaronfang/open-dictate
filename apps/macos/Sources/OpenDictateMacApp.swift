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
                Text("默认开启。识别结果会先套用个人词典，再按规则清理口癖与多余空白。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { reloadDictionary() }
        .onChange(of: settings.storePath) { _, _ in reloadDictionary() }
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
}

final class StatusController: NSObject, ObservableObject {
    static let shared = StatusController()

    private var item: NSStatusItem?
    private var statusMenu: NSMenu?
    private let hotkey = HotkeyMonitor(hotkey: .init(keyCode: 61))
    private let recorder = AudioRecorder()
    private let transcriber = SpeechTranscriber()
    private let settings = AppSettings()
    private let hud = HudWindow()
    private let injector = TextInjector()

    @Published var hotkeyActive = false

    var transcriberIsLoaded: Bool { transcriber.isSenseVoiceLoaded }

    func probeTranscribe(wavPath: String) async {
        let url = URL(fileURLWithPath: wavPath)
        do {
            let raw = try await transcriber.transcribe(wavURL: url, settings: settings)
            let text = TextIntelligence.process(raw, settings: settings)
            NSLog("PROBE result raw=\(raw) final=\(text)")
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
            selector: #selector(senseVoiceLoaded),
            name: .senseVoiceLoaded,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(senseVoiceWarmedUp),
            name: .senseVoiceWarmedUp,
            object: nil
        )

        hotkey.onHotkeyDown = { [weak self] in
            guard let self else { return }
            NSLog("Recording hotkey down")
            self.injector.rememberTarget()
            // Kick model load as early as possible (parallel with recording).
            if self.settings.sttEngine == .senseVoice, !self.transcriber.isSenseVoiceLoaded {
                self.transcriber.preload(settings: self.settings)
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
                    let text = TextIntelligence.process(raw, settings: self.settings)
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
        transcriber.preload(settings: settings)
    }

    func stop() {
        hotkey.stop()
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        statusMenu = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func installStatusItem(menuTarget: NSObject) {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "OpenDictate") {
            image.isTemplate = true
            item.button?.image = image
        }
        item.button?.toolTip = statusToolTip()

        let menu = NSMenu()
        menu.autoenablesItems = false

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
    }

    @objc private func screenParametersChanged() {
        guard let menuTarget = NSApp.delegate as? NSObject else { return }
        installStatusItem(menuTarget: menuTarget)
    }

    @objc private func senseVoiceLoaded() {
        item?.button?.toolTip = statusToolTip()
    }

    @objc private func senseVoiceWarmedUp() {
        item?.button?.toolTip = statusToolTip()
    }

    private func statusToolTip() -> String {
        if settings.sttEngine == .senseVoice, settings.senseVoiceModelsReady {
            if transcriber.isSenseVoiceWarmedUp {
                return "OpenDictate（就绪）"
            }
            if transcriber.isSenseVoiceLoaded {
                return "OpenDictate（已加载，后台预热中…）"
            }
            return "OpenDictate（模型加载中…）"
        }
        return "OpenDictate"
    }
}
