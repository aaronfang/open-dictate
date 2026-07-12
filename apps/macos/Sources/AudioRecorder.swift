import AVFoundation

final class AudioRecorder {
    enum State {
        case idle
        case recording
        case stopping
    }

    /// Result of the last Voice Processing enable attempt for logging.
    enum VoiceProcessingStatus: String {
        case off
        case on
        case fallback
    }

    private(set) var state: State = .idle
    private(set) var lastRecordingURL: URL?
    private(set) var lastVoiceProcessingStatus: VoiceProcessingStatus = .off
    /// Fired on the main queue when trailing silence is detected after speech (toggle auto-stop).
    var onTrailingSilence: (() -> Void)?

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var converter: AVAudioConverter?
    private var recordFormat: AVAudioFormat?

    private var autoStopEnabled = false
    private var speechHeard = false
    private var trailingSilenceLimit: Double = 1.1
    private var silenceAccum: Double = 0
    private var noiseFloorRMS: Float = 0.01
    private var noiseProbeSeconds: Double = 0
    private var autoStopFired = false
    private let vadLock = NSLock()

    func startRecording(
        enableVoiceProcessing: Bool = false,
        enableSilenceAutoStop: Bool = false,
        trailingSilenceSeconds: Double = 1.1
    ) throws -> URL {
        guard state == .idle else {
            return outputURL ?? URL(fileURLWithPath: "/dev/null")
        }

        if #available(macOS 14.0, *) {
            guard AVAudioApplication.shared.recordPermission == .granted else {
                throw recorderError("麦克风未授权")
            }
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw recorderError("麦克风未授权")
        }

        resetEngineIfNeeded()
        resetVADState(
            autoStop: enableSilenceAutoStop,
            trailingSilence: trailingSilenceSeconds
        )

        let input = engine.inputNode
        var voiceProcessingStatus: VoiceProcessingStatus = .off
        if enableVoiceProcessing {
            do {
                // Must be set while the engine is stopped.
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingStatus = .on
            } catch {
                NSLog(
                    "AudioRecorder: Voice Processing enable failed — falling back: %@",
                    error.localizedDescription
                )
                voiceProcessingStatus = .fallback
                resetEngineIfNeeded()
                resetVADState(
                    autoStop: enableSilenceAutoStop,
                    trailingSilence: trailingSilenceSeconds
                )
            }
        }
        lastVoiceProcessingStatus = voiceProcessingStatus
        let activeInput = engine.inputNode

        let inputFormat = activeInput.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw recorderError("未检测到可用的麦克风输入（sampleRate=\(inputFormat.sampleRate))")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(SenseVoiceConfig.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw recorderError("无法创建 16 kHz 录音格式")
        }

        let converter: AVAudioConverter?
        if inputFormat.sampleRate == targetFormat.sampleRate,
           inputFormat.channelCount == 1,
           inputFormat.commonFormat == .pcmFormatFloat32 {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw recorderError("无法创建录音重采样器")
            }
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            if inputFormat.channelCount > 1 {
                c.channelMap = [0]
            }
            converter = c
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open_dictate_\(UUID().uuidString).wav")
        outputURL = url
        file = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        self.converter = converter
        self.recordFormat = targetFormat

        activeInput.removeTap(onBus: 0)
        activeInput.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.state == .recording, let file = self.file else { return }
            do {
                if let converter = self.converter, let recordFormat = self.recordFormat {
                    let ratio = recordFormat.sampleRate / buffer.format.sampleRate
                    let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
                    guard let out = AVAudioPCMBuffer(pcmFormat: recordFormat, frameCapacity: max(capacity, 1)) else { return }
                    var error: NSError?
                    var consumed = false
                    let status = converter.convert(to: out, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let error {
                        NSLog("AudioRecorder convert error: \(error)")
                        return
                    }
                    if status != .error, out.frameLength > 0 {
                        try file.write(from: out)
                        self.observeEnergy(buffer: out)
                    }
                } else {
                    try file.write(from: buffer)
                    if buffer.format.commonFormat == .pcmFormatFloat32 {
                        self.observeEnergy(buffer: buffer)
                    }
                }
            } catch {
                NSLog("AudioRecorder write error: \(error)")
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanupAfterFailure()
            throw recorderError("音频引擎启动失败：\(error.localizedDescription)")
        }

        state = .recording
        NSLog(
            "AudioRecorder started: %@ (in=%.0fHz/%dch → 16kHz/mono voiceProcessing=%@ autoStop=%@)",
            url.path,
            inputFormat.sampleRate,
            inputFormat.channelCount,
            voiceProcessingStatus.rawValue,
            enableSilenceAutoStop ? "yes" : "no"
        )
        return url
    }

    func stopRecording() {
        guard state == .recording || state == .stopping else { return }
        if state == .recording {
            state = .stopping
        }

        releaseAudioHardware()
        file = nil
        converter = nil
        recordFormat = nil
        lastRecordingURL = outputURL
        state = .idle
        NSLog("AudioRecorder stopped: \(lastRecordingURL?.path ?? "nil")")
    }

    private func resetVADState(autoStop: Bool, trailingSilence: Double) {
        vadLock.lock()
        autoStopEnabled = autoStop
        trailingSilenceLimit = max(0.6, trailingSilence)
        speechHeard = false
        silenceAccum = 0
        noiseFloorRMS = 0.01
        noiseProbeSeconds = 0
        autoStopFired = false
        vadLock.unlock()
    }

    private func observeEnergy(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let rms = EnergyVAD.rms(channel, count: frames)
        let duration = Double(frames) / max(buffer.format.sampleRate, 1)

        var shouldFire = false
        vadLock.lock()
        if autoStopEnabled, !autoStopFired {
            if noiseProbeSeconds < 0.35 {
                if noiseProbeSeconds == 0 {
                    noiseFloorRMS = max(0.004, rms)
                } else {
                    noiseFloorRMS = min(noiseFloorRMS, max(0.004, rms * 0.85 + noiseFloorRMS * 0.15))
                }
                noiseProbeSeconds += duration
            }

            let threshold = max(0.015, noiseFloorRMS * 3.0)
            if rms >= threshold {
                speechHeard = true
                silenceAccum = 0
            } else if speechHeard {
                silenceAccum += duration
                if silenceAccum >= trailingSilenceLimit {
                    autoStopFired = true
                    shouldFire = true
                }
            }
        }
        vadLock.unlock()

        if shouldFire {
            NSLog(
                "AudioRecorder: trailing silence %.2fs after speech — auto-stop",
                trailingSilenceLimit
            )
            DispatchQueue.main.async { [weak self] in
                self?.onTrailingSilence?()
            }
        }
    }

    private func resetEngineIfNeeded() {
        releaseAudioHardware()
        converter = nil
        recordFormat = nil
    }

    private func cleanupAfterFailure() {
        releaseAudioHardware()
        file = nil
        converter = nil
        recordFormat = nil
        outputURL = nil
        state = .idle
        lastVoiceProcessingStatus = .off
    }

    /// Stop the engine, disable Voice Processing, and drop the I/O unit so the
    /// orange mic indicator / system audio ducking do not linger after dictation.
    private func releaseAudioHardware() {
        let input = engine.inputNode
        if engine.isRunning {
            input.removeTap(onBus: 0)
            engine.stop()
        } else {
            input.removeTap(onBus: 0)
        }

        if input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(false)
            } catch {
                NSLog(
                    "AudioRecorder: Voice Processing disable failed: %@",
                    error.localizedDescription
                )
            }
        }

        engine.reset()
        engine = AVAudioEngine()
    }

    private func recorderError(_ message: String) -> NSError {
        NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
