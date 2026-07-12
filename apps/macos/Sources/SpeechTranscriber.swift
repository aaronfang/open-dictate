import Foundation

enum STTEngine: String, CaseIterable, Identifiable {
    case senseVoice = "sensevoice"
    case whisper = "whisper"
    case volcengine = "volcengine"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .senseVoice:
            return "SenseVoice（推荐，中文更准）"
        case .whisper:
            return "whisper.cpp"
        case .volcengine:
            return "火山引擎（云端，音频出网）"
        }
    }
}

/// Optional boost for noisy rooms; default stays SenseVoice + normal mic path.
enum NoisySceneStrategy: String, CaseIterable, Identifiable {
    case off = "off"
    case boostDenoise = "boost_denoise"
    case preferWhisper = "prefer_whisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "关闭（默认）"
        case .boostDenoise:
            return "加强降噪（系统 VP）"
        case .preferWhisper:
            return "优先 Whisper"
        }
    }
}

final class SpeechTranscriber {
    private let whisper = WhisperTranscriber()
    private let providerLock = NSLock()
    /// Dedicated queue so CoreML `DispatchGroup.wait` never blocks Swift concurrency threads.
    private let loadQueue = DispatchQueue(label: "com.opendictate.sensevoice.load", qos: .userInitiated)
    private var senseVoiceProvider: SenseVoiceCoreMLProvider?
    private var senseVoiceCacheKey: String?
    private var loadTask: Task<Void, Error>?
    private var warmupTask: Task<Void, Never>?
    private(set) var isSenseVoiceLoaded = false
    private(set) var isSenseVoiceWarmedUp = false
    private(set) var didSenseVoiceLoadFail = false
    /// True while a SenseVoice load Task is in flight.
    var isSenseVoiceLoading: Bool { loadTask != nil && !isSenseVoiceLoaded }

    func transcribe(wavURL: URL, settings: AppSettings) async throws -> String {
        let engine = settings.sessionSTTEngine(whisperAvailable: whisperFallbackAvailable(settings: settings))
        switch engine {
        case .senseVoice:
            do {
                let text = try await transcribeWithSenseVoice(wavURL: wavURL, settings: settings)
                return try await maybeImproveWithWhisper(
                    senseVoiceText: text,
                    wavURL: wavURL,
                    settings: settings,
                    aggressive: settings.noisySceneStrategy == .boostDenoise
                )
            } catch let error as SenseVoiceCoreMLError {
                switch error {
                case .noSpeech, .emptyResult:
                    return try await whisperOrThrow(wavURL: wavURL, settings: settings, fallback: nil, underlying: error)
                case .weakResult(let weakText):
                    NSLog("SpeechTranscriber: SenseVoice weak — trying whisper.cpp")
                    return try await whisperOrThrow(
                        wavURL: wavURL,
                        settings: settings,
                        fallback: weakText,
                        underlying: error
                    )
                default:
                    throw error
                }
            }
        case .whisper:
            return try await transcribeWithWhisper(wavURL: wavURL, settings: settings)
        case .volcengine:
            return try await VolcengineAsrClient.transcribe(
                wavURL: wavURL,
                config: settings.volcengineConfig
            )
        }
    }

    /// If SenseVoice looks sparse vs duration, compare with whisper and keep the denser transcript.
    private func maybeImproveWithWhisper(
        senseVoiceText: String,
        wavURL: URL,
        settings: AppSettings,
        aggressive: Bool = false
    ) async throws -> String {
        guard whisperFallbackAvailable(settings: settings) else { return senseVoiceText }
        let seconds: Double
        do {
            let samples = try WavConverter.loadFloat32Mono16k(url: wavURL)
            seconds = Double(samples.count) / Double(SenseVoiceConfig.sampleRate)
        } catch {
            return senseVoiceText
        }
        let shouldCompare = aggressive
            || SenseVoiceCoreMLProvider.isWeakTranscript(senseVoiceText, audioSeconds: seconds)
        guard shouldCompare else {
            return senseVoiceText
        }
        NSLog(
            "SpeechTranscriber: SenseVoice compare whisper (%.1fs, chars=%d, aggressive=%@)",
            seconds,
            SenseVoiceCoreMLProvider.contentCharacterCount(senseVoiceText),
            aggressive ? "yes" : "no"
        )
        do {
            let whisperText = try await transcribeWithWhisper(wavURL: wavURL, settings: settings)
            let best = SenseVoiceCoreMLProvider.pickBetterTranscript(senseVoiceText, whisperText)
            NSLog(
                "SpeechTranscriber: pickBetter sv=%@ whisper=%@ → %@",
                senseVoiceText,
                whisperText,
                best
            )
            return best
        } catch {
            NSLog("SpeechTranscriber: whisper compare failed: %@", error.localizedDescription)
            return senseVoiceText
        }
    }

    private func whisperOrThrow(
        wavURL: URL,
        settings: AppSettings,
        fallback: String?,
        underlying: Error
    ) async throws -> String {
        guard whisperFallbackAvailable(settings: settings) else {
            if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fallback
            }
            throw underlying
        }
        do {
            let whisperText = try await transcribeWithWhisper(wavURL: wavURL, settings: settings)
            let trimmed = whisperText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if let fallback, !fallback.isEmpty { return fallback }
                throw underlying
            }
            if let fallback, !fallback.isEmpty {
                let best = SenseVoiceCoreMLProvider.pickBetterTranscript(fallback, trimmed)
                NSLog(
                    "SpeechTranscriber: whisper fallback pickBetter weak=%@ whisper=%@ → %@",
                    fallback,
                    trimmed,
                    best
                )
                return best
            }
            NSLog("SpeechTranscriber whisper fallback: %@", trimmed)
            return trimmed
        } catch {
            if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("SpeechTranscriber: whisper failed, using SenseVoice weak: %@", fallback)
                return fallback
            }
            throw underlying
        }
    }

    private func whisperFallbackAvailable(settings: AppSettings) -> Bool {
        let binary = NSString(string: settings.whisperBinary).expandingTildeInPath
        let model = NSString(string: settings.whisperModelPath).expandingTildeInPath
        let binaryOK = FileManager.default.isExecutableFile(atPath: binary)
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/whisper-cli")
        let modelOK = FileManager.default.fileExists(atPath: model)
        return binaryOK && modelOK
    }

    func isWhisperReady(settings: AppSettings) -> Bool {
        whisperFallbackAvailable(settings: settings)
    }

    /// Load models at launch; ANE warmup continues in background and must not block dictation.
    func preload(settings: AppSettings) {
        guard settings.sttEngine == .senseVoice, settings.senseVoiceModelsReady else { return }
        // Already loaded or load in flight — don't cancel/restart (hotkey may call this).
        if senseVoiceProvider != nil || loadTask != nil { return }

        isSenseVoiceLoaded = false
        isSenseVoiceWarmedUp = false
        didSenseVoiceLoadFail = false
        NotificationCenter.default.post(name: .senseVoiceLoadStarted, object: nil)

        loadTask = Task { [weak self] in
            guard let self else { return }
            let started = CFAbsoluteTimeGetCurrent()
            NSLog("SpeechTranscriber: SenseVoice loading models…")
            do {
                _ = try await self.loadSenseVoiceProviderAsync(settings: settings)
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                await MainActor.run {
                    self.isSenseVoiceLoaded = true
                    NotificationCenter.default.post(name: .senseVoiceLoaded, object: nil)
                }
                NSLog("SpeechTranscriber: SenseVoice loaded in %.1fs", elapsed)
            } catch {
                await MainActor.run {
                    self.loadTask = nil
                    self.didSenseVoiceLoadFail = true
                    NotificationCenter.default.post(name: .senseVoiceLoadFailed, object: nil)
                }
                NSLog("SpeechTranscriber: SenseVoice load failed: \(error)")
                throw error
            }
        }

        warmupTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.loadTask?.value
            } catch {
                NSLog("SpeechTranscriber: SenseVoice load failed before warmup: \(error)")
                return
            }
            guard !Task.isCancelled else { return }

            let started = CFAbsoluteTimeGetCurrent()
            do {
                let provider = try await self.loadSenseVoiceProviderAsync(settings: settings)
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.loadQueue.async {
                        do {
                            try provider.warmup()
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                await MainActor.run {
                    self.isSenseVoiceWarmedUp = true
                    NotificationCenter.default.post(name: .senseVoiceWarmedUp, object: nil)
                }
                NSLog("SpeechTranscriber: SenseVoice warmed up in %.1fs", elapsed)
            } catch {
                NSLog("SpeechTranscriber: SenseVoice warmup failed: \(error)")
            }
        }
    }

    private func transcribeWithSenseVoice(wavURL: URL, settings: AppSettings) async throws -> String {
        // Only wait for model *load*, never for full ANE warmup.
        if senseVoiceProvider == nil {
            if let loadTask {
                try await loadTask.value
            } else {
                preload(settings: settings)
                try await loadTask?.value
            }
        }

        let provider = try await loadSenseVoiceProviderAsync(settings: settings)
        let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.loadQueue.async {
                do {
                    cont.resume(returning: try provider.transcribe(wavURL: wavURL))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        NSLog("SpeechTranscriber SenseVoice: \(text)")
        return text
    }

    private func transcribeWithWhisper(wavURL: URL, settings: AppSettings) async throws -> String {
        let config = WhisperTranscriber.Config(
            binary: settings.whisperBinary,
            modelPath: settings.whisperModelPath,
            languageHint: settings.whisperLanguage
        )
        return try await whisper.transcribe(wavURL: wavURL, config: config)
    }

    private func loadSenseVoiceProviderAsync(settings: AppSettings) async throws -> SenseVoiceCoreMLProvider {
        try await withCheckedThrowingContinuation { cont in
            loadQueue.async {
                do {
                    cont.resume(returning: try self.loadSenseVoiceProvider(settings: settings))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func loadSenseVoiceProvider(settings: AppSettings) throws -> SenseVoiceCoreMLProvider {
        let language = SenseVoiceConfig.languageEmbedIndex(settings.senseVoiceLanguage)
        let textNorm = SenseVoiceConfig.textNormEmbedIndex(enableITN: settings.senseVoiceEnableITN)
        let cacheKey = [
            settings.senseVoiceModelsPath,
            settings.senseVoiceUseInt8 ? "int8" : "fp16",
            settings.senseVoiceUseFp32 ? "fp32" : "ane",
            "lang:\(language)",
            "itn:\(textNorm)",
        ].joined(separator: "|")

        providerLock.lock()
        defer { providerLock.unlock() }

        if let senseVoiceProvider, senseVoiceCacheKey == cacheKey {
            return senseVoiceProvider
        }

        let directory = URL(fileURLWithPath: NSString(string: settings.senseVoiceModelsPath).expandingTildeInPath)
        let provider = try SenseVoiceCoreMLProvider(config: .init(
            modelsDirectory: directory,
            useInt8Encoder: settings.senseVoiceUseInt8,
            useFp32Encoder: settings.senseVoiceUseFp32,
            language: language,
            textNorm: textNorm
        ))
        senseVoiceProvider = provider
        senseVoiceCacheKey = cacheKey
        return provider
    }

    func resetCachedProvider() {
        providerLock.lock()
        defer { providerLock.unlock() }
        senseVoiceProvider = nil
        senseVoiceCacheKey = nil
        isSenseVoiceLoaded = false
        isSenseVoiceWarmedUp = false
        didSenseVoiceLoadFail = false
        loadTask?.cancel()
        warmupTask?.cancel()
        loadTask = nil
        warmupTask = nil
    }
}
