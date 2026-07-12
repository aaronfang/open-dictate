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
    private let askHotkeyMonitor = HotkeyMonitor(keyCode: DictationHotkey.defaultAskKeyCode)
    private let escapeCancelMonitor = EscapeCancelMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = SpeechTranscriber()
    private let settings = AppSettings()
    private let hud = HudWindow()
    private let injector = TextInjector()

    private enum SessionKind {
        case dictate
        case ask
    }

    private var activeSession: SessionKind?
    private var isBusy = false
    private var workTask: Task<Void, Never>?
    private var workGeneration: UInt64 = 0
    private var askSelectedText: String?
    private var askUsedClipboardFallback = false
    /// Last successfully delivered dictation/Ask text (for spoken revision commands).
    private var lastDeliveredText: String?
    private var pendingCorrectionOriginal: String?
    private var correctionProbeToken: UInt64 = 0

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
            self?.handleDictationKeyDown()
        }
        hotkeyMonitor.onHotkeyUp = { [weak self] in
            self?.handleDictationKeyUp()
        }
        askHotkeyMonitor.onHotkeyDown = { [weak self] in
            self?.handleAskKeyDown()
        }
        askHotkeyMonitor.onHotkeyUp = { [weak self] in
            self?.handleAskKeyUp()
        }
        escapeCancelMonitor.onEscape = { [weak self] in
            self?.handleEscapeCancel() ?? false
        }

        applyDictationHotkeyFromSettings()
        applyAskHotkeyFromSettings()
        hotkeyMonitor.start()
        escapeCancelMonitor.start()
        if settings.enableAskAI {
            askHotkeyMonitor.start()
        }
        hotkeyActive = hotkeyMonitor.isActive
        settings.migrateLLMProviderIfNeeded()
        if settings.llmPolishProvider == .local {
            LocalLLMManager.shared.prefetchIfNeeded()
        }
        // Auto-load SenseVoice at launch so the first dictation isn't blocked.
        transcriber.preload(settings: settings)
        refreshStatusAppearance()
    }

    private func handleDictationKeyDown() {
        switch settings.dictationTriggerMode {
        case .hold:
            beginSession(.dictate)
        case .toggle:
            if activeSession == .dictate {
                endSession()
            } else {
                beginSession(.dictate)
            }
        }
    }

    private func handleDictationKeyUp() {
        guard settings.dictationTriggerMode == .hold else { return }
        guard activeSession == .dictate else { return }
        endSession()
    }

    private func handleAskKeyDown() {
        guard settings.enableAskAI else { return }
        switch settings.dictationTriggerMode {
        case .hold:
            beginSession(.ask)
        case .toggle:
            if activeSession == .ask {
                endSession()
            } else {
                beginSession(.ask)
            }
        }
    }

    private func handleAskKeyUp() {
        guard settings.enableAskAI else { return }
        guard settings.dictationTriggerMode == .hold else { return }
        guard activeSession == .ask else { return }
        endSession()
    }

    /// Esc while recording or post-processing: abort without pasting.
    @discardableResult
    private func handleEscapeCancel() -> Bool {
        guard activeSession != nil || isBusy || workTask != nil else { return false }
        abortCurrentWork(reason: "escape")
        return true
    }

    private func abortCurrentWork(reason: String) {
        NSLog("Session abort: %@", reason)
        workGeneration &+= 1
        workTask?.cancel()
        workTask = nil

        let wasRecording = activeSession != nil
        activeSession = nil
        askSelectedText = nil
        askUsedClipboardFallback = false
        recorder.onTrailingSilence = nil
        if wasRecording || recorder.state == .recording || recorder.state == .stopping {
            recorder.stopRecording()
        }
        isBusy = false
        injector.cancelPendingPaste()
        hud.showTemporary("已取消", style: .cancel, detail: "录音与识别已中止", duration: 1.4)
    }

    private func flashHUD(
        _ text: String,
        style: HudWindow.Style,
        detail: String? = nil,
        duration: TimeInterval = 1.8
    ) {
        hud.showTemporary(text, style: style, detail: detail, duration: duration)
    }

    private func beginSession(_ kind: SessionKind) {
        guard !isBusy else {
            flashHUD("正在处理上一次结果…", style: .warning, detail: "可按 Esc 取消", duration: 1.4)
            return
        }
        guard activeSession == nil else { return }

        // Never let a previous delayed Cmd+V fire into this new session.
        injector.cancelPendingPaste()
        // Learn corrections from the previous paste before starting a new recording.
        probeAndLearnCorrectionIfNeeded()

        if kind == .ask {
            settings.migrateLLMProviderIfNeeded()
            if settings.llmPolishProvider == .off {
                flashHUD("Ask AI 需要开启润色", style: .warning, detail: "请先开启本地或 DeepSeek", duration: 2.2)
                return
            }
            if settings.llmPolishProvider == .deepseek, !settings.deepSeekConfigured {
                flashHUD("请先配置 DeepSeek API Key", style: .warning, duration: 2.2)
                return
            }
            guard let capture = injector.captureSelectedText(
                allowClipboardFallback: settings.askAllowClipboardFallback
            ), !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let appHint = injector.targetAppName.map { "（\($0)）" } ?? ""
                flashHUD(
                    "请先选中要处理的文本\(appHint)",
                    style: .error,
                    detail: settings.askAllowClipboardFallback
                        ? "选区/Cmd+C 失败且剪贴板为空"
                        : "可开启「选区失败时使用剪贴板」，或先 Cmd+C",
                    duration: 2.6
                )
                return
            }
            if capture.source == .clipboard {
                NSLog("Ask selection: proceeding with clipboard fallback")
            }
            askSelectedText = capture.text
            askUsedClipboardFallback = capture.source == .clipboard
        } else {
            askSelectedText = nil
            askUsedClipboardFallback = false
            injector.rememberTarget()
            lastDictationBundleId = injector.targetBundleId
            lastDictationAppName = injector.targetAppName
        }

        let whisperReady = transcriber.isWhisperReady(settings: settings)
        let sessionEngine = settings.sessionSTTEngine(whisperAvailable: whisperReady)
        if sessionEngine == .volcengine, !settings.volcengineConfigured {
            flashHUD("请先配置火山引擎", style: .warning, detail: "设置 → 语音识别 → API Key", duration: 2.2)
            askSelectedText = nil
            return
        }

        activeSession = kind
        NSLog("Session begin: \(kind)")

        if settings.noisySceneStrategy == .preferWhisper, !whisperReady {
            NSLog("Noisy strategy preferWhisper: whisper not ready — keeping %@", settings.sttEngine.rawValue)
        }

        if sessionEngine == .senseVoice, !transcriber.isSenseVoiceLoaded {
            transcriber.preload(settings: settings)
            refreshStatusAppearance()
        }

        let loading = sessionEngine == .senseVoice && !transcriber.isSenseVoiceLoaded
        let escHint = "Esc 取消"
        let recordingTitle: String
        let recordingDetail: String?
        switch (kind, settings.dictationTriggerMode, loading) {
        case (.dictate, .toggle, true):
            recordingTitle = "录音中"
            recordingDetail = "再按结束 · 模型加载中 · \(escHint)"
        case (.dictate, .toggle, false):
            recordingTitle = "录音中"
            recordingDetail = "再按热键结束 · \(escHint)"
        case (.dictate, .hold, true):
            recordingTitle = "正在录音"
            recordingDetail = "松开结束 · 模型加载中 · \(escHint)"
        case (.dictate, .hold, false):
            recordingTitle = "正在录音"
            recordingDetail = "松开结束 · \(escHint)"
        case (.ask, .toggle, _) where askUsedClipboardFallback:
            recordingTitle = "Ask：说出指令"
            recordingDetail = "已用剪贴板 · 再按结束 · \(escHint)"
        case (.ask, .hold, _) where askUsedClipboardFallback:
            recordingTitle = "Ask：说出指令"
            recordingDetail = "已用剪贴板 · 按住说话 · \(escHint)"
        case (.ask, .toggle, _):
            recordingTitle = "Ask：说出指令"
            recordingDetail = "再按结束 · \(escHint)"
        case (.ask, .hold, _):
            recordingTitle = "Ask：说出指令"
            recordingDetail = "按住说话 · \(escHint)"
        }
        hud.show(recordingTitle, style: .recording, detail: recordingDetail)

        recorder.onTrailingSilence = { [weak self] in
            guard let self else { return }
            // Auto-stop is intended for toggle mode; hold mode ends on key-up.
            guard self.settings.dictationTriggerMode == .toggle,
                  self.activeSession != nil,
                  self.recorder.state == .recording else { return }
            NSLog("Session auto-stop: trailing silence")
            self.endSession()
        }

        do {
            let autoStop = settings.enableSilenceAutoStop
                && settings.dictationTriggerMode == .toggle
            let useVP = settings.sessionVoiceProcessing
            _ = try recorder.startRecording(
                enableVoiceProcessing: useVP,
                enableSilenceAutoStop: autoStop
            )
            NSLog(
                "Session record voiceProcessing=%@ autoStop=%@ noisy=%@ engine=%@",
                recorder.lastVoiceProcessingStatus.rawValue,
                autoStop ? "yes" : "no",
                settings.noisySceneStrategy.rawValue,
                sessionEngine.rawValue
            )
        } catch {
            NSLog("startRecording error: \(error)")
            activeSession = nil
            askSelectedText = nil
            recorder.onTrailingSilence = nil
            flashHUD(
                "录音失败",
                style: .error,
                detail: (error as NSError).localizedDescription,
                duration: 2.4
            )
        }
    }

    private func endSession() {
        guard let kind = activeSession else { return }
        activeSession = nil
        recorder.onTrailingSilence = nil
        askUsedClipboardFallback = false
        NSLog("Session end: \(kind)")
        recorder.stopRecording()
        hud.hide()

        guard let wavURL = recorder.lastRecordingURL else {
            askSelectedText = nil
            flashHUD("未找到录音文件", style: .error, duration: 1.8)
            return
        }

        let selectedForAsk = askSelectedText
        askSelectedText = nil
        isBusy = true
        workGeneration &+= 1
        let generation = workGeneration

        workTask = Task {
            defer {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.workGeneration == generation else { return }
                    self.isBusy = false
                    self.workTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.hud.show(
                    self.recognitionStatusText(),
                    style: .processing,
                    detail: "Esc 取消"
                )
            }
            do {
                // Silence / mic bump: do not STT, do not paste old clipboard.
                if self.isSilentRecording(wavURL) {
                    NSLog("Session soft-skip: silence / too short")
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.injector.cancelPendingPaste()
                        self.flashHUD("未检测到语音", style: .warning, duration: 1.5)
                    }
                    return
                }

                guard !Task.isCancelled else { return }
                let raw = try await self.transcriber.transcribe(wavURL: wavURL, settings: self.settings)
                guard !Task.isCancelled else { return }

                if TextIntelligence.isEffectivelyEmptyTranscript(raw) {
                    NSLog("Session soft-skip: empty/weak transcript %@", raw)
                    await MainActor.run {
                        self.injector.cancelPendingPaste()
                        self.flashHUD(
                            kind == .ask ? "未识别到指令" : "未识别到有效语音",
                            style: .warning,
                            duration: 1.6
                        )
                    }
                    return
                }

                switch kind {
                case .dictate:
                    await self.finishDictate(raw: raw, generation: generation)
                case .ask:
                    await self.finishAsk(
                        selected: selectedForAsk ?? "",
                        instructionRaw: raw,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                NSLog("Session cancelled during transcribe")
            } catch let error as SenseVoiceCoreMLError {
                guard !Task.isCancelled else { return }
                await self.handleTranscribeError(error)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("transcribe error: \(error.localizedDescription)")
                await MainActor.run {
                    self.injector.cancelPendingPaste()
                    self.flashHUD(
                        "识别失败",
                        style: .error,
                        detail: error.localizedDescription,
                        duration: 2.5
                    )
                }
            }
        }
    }

    private func isSilentRecording(_ wavURL: URL) -> Bool {
        do {
            let samples = try WavConverter.loadFloat32Mono16k(url: wavURL)
            let analysis = EnergyVAD.analyze(samples)
            let silent = EnergyVAD.looksLikeSilence(samples)
            if silent {
                NSLog(
                    "Audio silence gate: frames=%d peak=%.4f speech=%.2fs floor=%.4f duration=%.2fs",
                    samples.count,
                    analysis.peak,
                    analysis.speechDurationSeconds,
                    analysis.noiseFloor,
                    Double(samples.count) / Double(SenseVoiceConfig.sampleRate)
                )
            }
            return silent
        } catch {
            NSLog("Audio silence gate skipped: \(error.localizedDescription)")
            return false
        }
    }

    private func recognitionStatusText() -> String {
        let engine = settings.sessionSTTEngine(
            whisperAvailable: transcriber.isWhisperReady(settings: settings)
        )
        if engine == .senseVoice {
            if !transcriber.isSenseVoiceLoaded {
                return "模型加载中…"
            }
            if !transcriber.isSenseVoiceWarmedUp {
                return "正在识别…"
            }
        }
        if engine == .whisper {
            return "正在识别…"
        }
        if engine == .volcengine {
            return "云端识别中…"
        }
        return "正在识别…"
    }

    private func finishDictate(raw: String, generation: UInt64) async {
        guard workGeneration == generation, !Task.isCancelled else { return }
        let appId = injector.targetBundleId
        let provider = settings.llmPolishProvider
        if provider == .local {
            let llm = LocalLLMManager.shared
            if llm.isDownloading || !LocalLLMAssets.isReady {
                await MainActor.run {
                    let pct = Int((llm.overallProgress * 100).rounded(.down))
                    self.hud.show("正在下载本地模型…\(pct)%", style: .processing, detail: "Esc 取消")
                }
                try? await llm.ensureReady()
            }
            guard workGeneration == generation, !Task.isCancelled else { return }
            if LocalLLMAssets.isReady {
                await MainActor.run {
                    self.hud.show("正在润色…", style: .processing, detail: "Esc 取消")
                }
            }
        } else if provider == .deepseek, settings.deepSeekConfigured {
            await MainActor.run {
                self.hud.show("正在润色…", style: .processing, detail: "Esc 取消")
            }
        }
        guard workGeneration == generation, !Task.isCancelled else { return }
        let previous = lastDeliveredText
        let processed = await TextIntelligence.process(
            raw,
            settings: settings,
            appId: appId,
            previousText: previous
        )
        guard workGeneration == generation, !Task.isCancelled else { return }
        NSLog(
            "TextIntelligence app=%@ tone=%@ profile=%@ llm=%@ provider=%@",
            processed.appId ?? "nil",
            processed.tone ?? "none",
            processed.profileApplied ? "yes" : "no",
            processed.llmApplied ? "yes" : "no",
            processed.llmProvider.rawValue
        )
        let text = processed.text
        let rawForHistory = raw
        await MainActor.run {
            guard self.workGeneration == generation else { return }
            self.hud.hide()
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || TextIntelligence.isEffectivelyEmptyTranscript(text) {
                self.injector.cancelPendingPaste()
                self.flashHUD("未识别到有效文本", style: .warning, duration: 1.6)
                return
            }
            // Never re-paste last delivery when this turn had no real speech substance.
            if let last = self.lastDeliveredText, text == last {
                let weakRaw = TextIntelligence.isEffectivelyEmptyTranscript(rawForHistory)
                    || SenseVoiceCoreMLProvider.contentCharacterCount(rawForHistory) < 4
                if weakRaw {
                    self.injector.cancelPendingPaste()
                    self.flashHUD("未识别到有效语音", style: .warning, duration: 1.6)
                    return
                }
            }
            let outcome = self.injector.insert(text: text)
            self.lastDeliveredText = text
            self.recordHistory(raw: rawForHistory, final: text, appId: appId, source: "dictate")
            self.scheduleCorrectionProbe(delivered: text)
            switch outcome {
            case .clipboardOnly:
                self.flashHUD(
                    "已复制到剪贴板",
                    style: .info,
                    detail: "按 Cmd+V 粘贴",
                    duration: 2.5
                )
            case .pasted:
                self.flashHUD("已上屏", style: .success, duration: 1.1)
            }
        }
    }

    private func finishAsk(selected: String, instructionRaw: String, generation: UInt64) async {
        guard workGeneration == generation, !Task.isCancelled else { return }
        let instruction = instructionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !TextIntelligence.isEffectivelyEmptyTranscript(instruction) else {
            await MainActor.run {
                self.injector.cancelPendingPaste()
                self.flashHUD("未识别到指令", style: .warning, duration: 1.8)
            }
            return
        }

        if settings.llmPolishProvider == .local {
            let llm = LocalLLMManager.shared
            if llm.isDownloading || !LocalLLMAssets.isReady {
                await MainActor.run {
                    let pct = Int((llm.overallProgress * 100).rounded(.down))
                    self.hud.show("正在下载本地模型…\(pct)%", style: .processing, detail: "Esc 取消")
                }
                try? await llm.ensureReady()
            }
        }
        guard workGeneration == generation, !Task.isCancelled else { return }
        await MainActor.run {
            self.hud.show("Ask AI 处理中…", style: .processing, detail: "Esc 取消")
        }

        do {
            let result = try await TextIntelligence.ask(
                selected: selected,
                instruction: instruction,
                settings: settings
            )
            guard workGeneration == generation, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.workGeneration == generation else { return }
                self.hud.hide()
                if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.injector.cancelPendingPaste()
                    self.flashHUD("Ask 未返回有效文本", style: .warning, duration: 1.8)
                    return
                }
                // Model sometimes ignores the selection and returns the spoken instruction
                // verbatim — that feels like "dictation via Ask".
                if TextIntelligence.isAskResultInstructionLeak(
                    selected: selected,
                    instruction: instruction,
                    result: result
                ) {
                    NSLog(
                        "Ask rejected instruction leak: instruction=%@ result=%@",
                        instruction,
                        result
                    )
                    self.injector.cancelPendingPaste()
                    self.flashHUD(
                        "Ask 未改写选区",
                        style: .warning,
                        detail: "请先选中文本，再说出改写指令",
                        duration: 2.4
                    )
                    return
                }
                let outcome = self.injector.insert(text: result, refreshFocus: false)
                self.lastDeliveredText = result
                self.recordHistory(raw: instruction, final: result, appId: self.injector.targetBundleId, source: "ask")
                self.scheduleCorrectionProbe(delivered: result)
                switch outcome {
                case .clipboardOnly:
                    self.flashHUD(
                        "已复制到剪贴板",
                        style: .info,
                        detail: "按 Cmd+V 粘贴",
                        duration: 2.5
                    )
                case .pasted:
                    self.flashHUD("已上屏", style: .success, duration: 1.1)
                }
            }
        } catch {
            guard workGeneration == generation, !Task.isCancelled else { return }
            NSLog("Ask AI error: \(error.localizedDescription)")
            await MainActor.run {
                self.flashHUD(
                    "Ask 失败",
                    style: .error,
                    detail: error.localizedDescription,
                    duration: 2.5
                )
            }
        }
    }

    private func handleTranscribeError(_ error: SenseVoiceCoreMLError) async {
        await MainActor.run {
            self.injector.cancelPendingPaste()
        }
        switch error {
        case .noSpeech, .emptyResult:
            NSLog("transcribe soft-skip: \(error.localizedDescription)")
            await MainActor.run {
                self.flashHUD("未识别到有效语音", style: .warning, duration: 1.8)
            }
        case .weakResult:
            // Should have been resolved in SpeechTranscriber; treat as soft skip if it escapes.
            NSLog("transcribe weakResult escaped: \(error.localizedDescription)")
            await MainActor.run {
                self.flashHUD("未识别到有效语音", style: .warning, duration: 1.8)
            }
        default:
            NSLog("transcribe error: \(error.localizedDescription)")
            await MainActor.run {
                self.flashHUD(
                    "识别失败",
                    style: .error,
                    detail: error.localizedDescription,
                    duration: 2.5
                )
            }
        }
    }

    // MARK: - History & dictionary learning

    private func recordHistory(raw: String, final: String, appId: String?, source: String) {
        guard settings.enableDictationHistory else { return }
        do {
            let store = try LocalStore(path: settings.storePath)
            try store.insertHistory(rawText: raw, finalText: final, appId: appId, source: source)
            try store.pruneHistory(retentionDays: settings.historyRetentionDays)
            NSLog("History: saved source=%@ chars=%d", source, final.count)
        } catch {
            NSLog("History: save failed: %@", error.localizedDescription)
        }
    }

    private func scheduleCorrectionProbe(delivered: String) {
        guard settings.enableAutoDictionaryLearn else { return }
        pendingCorrectionOriginal = delivered
        correctionProbeToken &+= 1
        let token = correctionProbeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, token == self.correctionProbeToken else { return }
            self.probeAndLearnCorrectionIfNeeded()
        }
    }

    private func probeAndLearnCorrectionIfNeeded() {
        guard settings.enableAutoDictionaryLearn else { return }
        guard let original = pendingCorrectionOriginal,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let field = injector.focusedStringValue(refreshFocus: true),
              let corrected = CorrectionLearner.findCorrectedVariant(original: original, in: field) else {
            return
        }

        let pairs = CorrectionLearner.extractPairs(from: original, to: corrected)
        guard !pairs.isEmpty else { return }

        do {
            let store = try LocalStore(path: settings.storePath)
            var learned: [String] = []
            for pair in pairs {
                try store.upsert(phrase: pair.phrase, replacement: pair.replacement)
                learned.append("\(pair.phrase)→\(pair.replacement)")
                NSLog("Dictionary learn: %@ → %@", pair.phrase, pair.replacement)
            }
            pendingCorrectionOriginal = nil
            correctionProbeToken &+= 1
            if let first = learned.first {
                let more = learned.count > 1 ? " 等\(learned.count)条" : ""
                flashHUD("已记入词典", style: .success, detail: "\(first)\(more)", duration: 2.2)
            }
        } catch {
            NSLog("Dictionary learn failed: %@", error.localizedDescription)
        }
    }

    /// Reload push-to-talk key from settings (call after user changes hotkey).
    func applyDictationHotkeyFromSettings() {
        let hotkey = settings.dictationHotkey
        hotkeyMonitor.update(hotkey: hotkey)
        currentHotkeyLabel = hotkey.settingsLabel(mode: settings.dictationTriggerMode)
        hotkeyActive = hotkeyMonitor.isActive
        NSLog(
            "Applied dictation hotkey: %@ (%@) mode=%@",
            hotkey.displayName,
            hotkey.id,
            settings.dictationTriggerMode.rawValue
        )
    }

    func applyAskHotkeyFromSettings() {
        let hotkey = settings.askAIHotkey
        let wasActive = askHotkeyMonitor.isActive
        askHotkeyMonitor.update(hotkey: hotkey)
        if settings.enableAskAI {
            if !askHotkeyMonitor.isActive {
                askHotkeyMonitor.start()
            }
        } else if wasActive || askHotkeyMonitor.isActive {
            askHotkeyMonitor.stop()
        }
        NSLog(
            "Applied Ask hotkey: %@ (%@) enabled=%@",
            hotkey.displayName,
            hotkey.id,
            settings.enableAskAI ? "yes" : "no"
        )
    }

    /// Temporarily stop listening while the settings UI captures a new hotkey.
    func pauseHotkeyForCapture() {
        hotkeyMonitor.stop()
        askHotkeyMonitor.stop()
        escapeCancelMonitor.stop()
        hotkeyActive = false
    }

    func resumeHotkeyAfterCapture() {
        applyDictationHotkeyFromSettings()
        applyAskHotkeyFromSettings()
        if !hotkeyMonitor.isActive {
            hotkeyMonitor.start()
        }
        if settings.enableAskAI, !askHotkeyMonitor.isActive {
            askHotkeyMonitor.start()
        }
        if !escapeCancelMonitor.isActive {
            escapeCancelMonitor.start()
        }
        hotkeyActive = hotkeyMonitor.isActive
    }

    func stop() {
        statusItemWatchdog?.invalidate()
        statusItemWatchdog = nil
        workGeneration &+= 1
        workTask?.cancel()
        workTask = nil
        hotkeyMonitor.stop()
        askHotkeyMonitor.stop()
        escapeCancelMonitor.stop()
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
        case .idle:
            switch settings.sttEngine {
            case .volcengine:
                return settings.volcengineConfigured
                    ? "语音识别：火山引擎（云端）"
                    : "语音识别：火山引擎未配置"
            case .whisper:
                return "语音识别：whisper.cpp"
            case .senseVoice:
                return "语音识别：SenseVoice"
            }
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
