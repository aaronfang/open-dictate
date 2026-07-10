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

final class StatusController: NSObject, ObservableObject {
    static let shared = StatusController()

    private var item: NSStatusItem?
    private var statusMenu: NSMenu?
    private var modelStatusMenuItem: NSMenuItem?
    private var localLLMStatusMenuItem: NSMenuItem?
    private var loadingSpinner: NSProgressIndicator?
    private var statusItemWatchdog: Timer?
    private var menuTarget: NSObject?
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = SpeechTranscriber()
    private let settings = AppSettings()
    private let hud = HudWindow()
    private let injector = TextInjector()

    @Published var hotkeyActive = false
    @Published var currentHotkeyLabel = DictationHotkey.default.settingsLabel
    private(set) var lastDictationBundleId: String?
    private(set) var lastDictationAppName: String?

    var transcriberIsLoaded: Bool { transcriber.isSenseVoiceLoaded }

    private enum ModelUIState {
        case localDownloading
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
        self.menuTarget = menuTarget
        // Defer one run-loop turn so launch-time screen-parameter churn
        // doesn't race the first status-item install.
        DispatchQueue.main.async {
            self.installStatusItem(menuTarget: menuTarget)
            self.startStatusItemWatchdog()
        }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshModelStatusUI),
            name: .localLLMStatusChanged,
            object: nil
        )

        hotkeyMonitor.onHotkeyDown = { [weak self] in
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
        hotkeyMonitor.onHotkeyUp = { [weak self] in
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
                    let provider = self.settings.llmPolishProvider
                    if provider == .local {
                        let llm = LocalLLMManager.shared
                        if llm.isDownloading || !LocalLLMAssets.isReady {
                            await MainActor.run {
                                let pct = Int((llm.overallProgress * 100).rounded(.down))
                                self.hud.show(text: "正在下载本地模型…\(pct)%")
                            }
                            try? await llm.ensureReady()
                        }
                        if LocalLLMAssets.isReady {
                            await MainActor.run { self.hud.show(text: "正在润色…") }
                        }
                    } else if provider == .deepseek, self.settings.deepSeekConfigured {
                        await MainActor.run {
                            self.hud.show(text: "正在润色…")
                        }
                    }
                    let processed = await TextIntelligence.process(raw, settings: self.settings, appId: appId)
                    NSLog(
                        "TextIntelligence app=%@ tone=%@ profile=%@ llm=%@ provider=%@",
                        processed.appId ?? "nil",
                        processed.tone ?? "none",
                        processed.profileApplied ? "yes" : "no",
                        processed.llmApplied ? "yes" : "no",
                        processed.llmProvider.rawValue
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
                        NSLog("transcribe soft-skip: \(error.localizedDescription)")
                        await MainActor.run {
                            self.hud.show(text: "未识别到有效语音")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                self.hud.hide()
                            }
                        }
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

        applyDictationHotkeyFromSettings()
        hotkeyMonitor.start()
        hotkeyActive = hotkeyMonitor.isActive
        settings.migrateLLMProviderIfNeeded()
        if settings.llmPolishProvider == .local {
            LocalLLMManager.shared.prefetchIfNeeded()
        }
        // Auto-load SenseVoice at launch so the first dictation isn't blocked.
        transcriber.preload(settings: settings)
        refreshStatusAppearance()
    }

    /// Reload push-to-talk key from settings (call after user changes hotkey).
    func applyDictationHotkeyFromSettings() {
        let hotkey = settings.dictationHotkey
        hotkeyMonitor.update(keyCode: hotkey.keyCode)
        currentHotkeyLabel = hotkey.settingsLabel
        hotkeyActive = hotkeyMonitor.isActive
        NSLog("Applied dictation hotkey: \(hotkey.displayName) (\(hotkey.keyCode))")
    }

    /// Temporarily stop listening while the settings UI captures a new hotkey.
    func pauseHotkeyForCapture() {
        hotkeyMonitor.stop()
        hotkeyActive = false
    }

    func resumeHotkeyAfterCapture() {
        applyDictationHotkeyFromSettings()
        if !hotkeyMonitor.isActive {
            hotkeyMonitor.start()
        }
        hotkeyActive = hotkeyMonitor.isActive
    }

    func stop() {
        statusItemWatchdog?.invalidate()
        statusItemWatchdog = nil
        hotkeyMonitor.stop()
        clearLoadingSpinner()
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        statusMenu = nil
        modelStatusMenuItem = nil
        localLLMStatusMenuItem = nil
        menuTarget = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func installStatusItem(menuTarget: NSObject) {
        // Keep the existing item if possible — remove+recreate is what made
        // the icon flash then vanish on multi-display Macs.
        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            created.isVisible = true
            self.item = created
            NSLog("StatusItem created")
        }

        guard let item else { return }
        item.isVisible = true
        item.length = NSStatusItem.squareLength

        guard let button = item.button else {
            NSLog("StatusItem: button is nil — menu bar may be full or unavailable")
            return
        }
        button.imagePosition = .imageOnly
        button.toolTip = "OpenDictate"

        let menu = NSMenu()
        menu.autoenablesItems = false

        let modelStatus = NSMenuItem(title: "语音识别：…", action: nil, keyEquivalent: "")
        modelStatus.isEnabled = false
        menu.addItem(modelStatus)
        modelStatusMenuItem = modelStatus

        let localStatus = NSMenuItem(title: "文字润色：…", action: nil, keyEquivalent: "")
        localStatus.isEnabled = false
        menu.addItem(localStatus)
        localLLMStatusMenuItem = localStatus
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
        self.statusMenu = menu
        setStatusSymbol("mic.fill", on: button)
        refreshStatusAppearance()
        NSLog(
            "StatusItem ready visible=%@ length=%.0f hasImage=%@",
            item.isVisible ? "yes" : "no",
            item.length,
            button.image != nil ? "yes" : "no"
        )
    }

    private func startStatusItemWatchdog() {
        statusItemWatchdog?.invalidate()
        // Re-assert visibility for a short window after launch / display changes.
        var ticks = 0
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            ticks += 1
            self.ensureStatusItemVisible(reason: "watchdog")
            if ticks >= 30 {
                timer.invalidate()
                self.statusItemWatchdog = nil
            }
        }
        statusItemWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func ensureStatusItemVisible(reason: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.ensureStatusItemVisible(reason: reason) }
            return
        }
        if item == nil, let menuTarget {
            NSLog("StatusItem missing (%@) — reinstalling", reason)
            installStatusItem(menuTarget: menuTarget)
            return
        }
        guard let item else { return }
        if !item.isVisible {
            NSLog("StatusItem was hidden (%@) — restoring", reason)
            item.isVisible = true
        }
        item.length = NSStatusItem.squareLength
        if item.button?.image == nil {
            refreshStatusAppearance()
        }
    }

    @objc private func screenParametersChanged() {
        NSLog("StatusItem: screen parameters changed — refreshing visibility only")
        DispatchQueue.main.async {
            self.ensureStatusItemVisible(reason: "screen-change")
            self.refreshStatusAppearance()
            self.startStatusItemWatchdog()
        }
    }

    @objc private func refreshModelStatusUI() {
        DispatchQueue.main.async {
            self.ensureStatusItemVisible(reason: "model-status")
            self.refreshStatusAppearance()
        }
    }

    private func modelUIState() -> ModelUIState {
        if settings.llmPolishProvider == .local, LocalLLMManager.shared.isDownloading {
            return .localDownloading
        }
        guard settings.sttEngine == .senseVoice else { return .idle }
        guard settings.senseVoiceModelsReady else { return .missingModels }
        if transcriber.isSenseVoiceWarmedUp { return .ready }
        if transcriber.isSenseVoiceLoaded { return .warming }
        if transcriber.didSenseVoiceLoadFail { return .failed }
        return .loading
    }

    private func refreshStatusAppearance() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.refreshStatusAppearance() }
            return
        }
        guard let item else { return }
        item.isVisible = true
        item.length = NSStatusItem.squareLength
        guard let button = item.button else { return }

        let state = modelUIState()
        let llm = LocalLLMManager.shared
        button.toolTip = combinedToolTip(stt: state, llm: llm)
        modelStatusMenuItem?.title = modelStatusTitle(for: state)
        localLLMStatusMenuItem?.isHidden = false
        localLLMStatusMenuItem?.title = textPolishStatusTitle()

        switch state {
        case .loading, .localDownloading, .warming:
            setStatusSymbol("mic", on: button)
        case .ready, .idle:
            setStatusSymbol("mic.fill", on: button)
        case .missingModels, .failed:
            setStatusSymbol("mic.slash", on: button)
        }
    }

    private func textPolishStatusTitle() -> String {
        switch settings.llmPolishProvider {
        case .off:
            return "文字润色：关闭"
        case .local:
            return LocalLLMManager.shared.statusMenuTitle
        case .deepseek:
            if settings.deepSeekConfigured {
                return "文字润色：DeepSeek 已配置"
            }
            return "文字润色：DeepSeek 未配置"
        }
    }

    private func combinedToolTip(stt: ModelUIState, llm: LocalLLMManager) -> String {
        var parts: [String] = [statusToolTip(for: stt)]
        switch settings.llmPolishProvider {
        case .off:
            parts.append("文字润色关闭")
        case .local:
            if let suffix = llm.statusToolTipSuffix {
                parts.append(suffix)
            }
        case .deepseek:
            parts.append(settings.deepSeekConfigured ? "DeepSeek 已配置" : "DeepSeek 未配置")
        }
        return parts.joined(separator: " · ")
    }

    private func setStatusSymbol(_ name: String, on button: NSStatusBarButton) {
        item?.length = NSStatusItem.squareLength
        item?.isVisible = true

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "OpenDictate")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.title = "OD"
            button.imagePosition = .imageLeft
        }
    }

    private func clearLoadingSpinner() {
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.removeFromSuperview()
        loadingSpinner = nil
    }

    private func modelStatusTitle(for state: ModelUIState) -> String {
        switch state {
        case .localDownloading: return "语音识别：\(transcriber.isSenseVoiceLoaded ? "就绪" : "加载中…")"
        case .loading: return "语音识别：加载中…"
        case .warming: return "语音识别：已加载（预热中）"
        case .ready: return "语音识别：就绪"
        case .failed: return "语音识别：加载失败"
        case .missingModels: return "语音识别：未下载"
        case .idle: return "语音识别：whisper.cpp"
        }
    }

    private func statusToolTip(for state: ModelUIState) -> String {
        switch state {
        case .localDownloading: return "OpenDictate（文字润色模型下载中…）"
        case .loading: return "OpenDictate（语音识别加载中…）"
        case .warming: return "OpenDictate（语音识别已加载，后台预热中…）"
        case .ready: return "OpenDictate（语音识别就绪）"
        case .failed: return "OpenDictate（语音识别加载失败）"
        case .missingModels: return "OpenDictate（SenseVoice 模型未下载）"
        case .idle: return "OpenDictate"
        }
    }
}
