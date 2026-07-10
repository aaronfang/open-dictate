import AVFoundation

final class AudioRecorder {
    enum State {
        case idle
        case recording
        case stopping
    }

    private(set) var state: State = .idle
    private(set) var lastRecordingURL: URL?
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var converter: AVAudioConverter?
    private var recordFormat: AVAudioFormat?

    func startRecording() throws -> URL {
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

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
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
            converter = c
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open_dictate_\(UUID().uuidString).wav")
        outputURL = url
        file = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        self.converter = converter
        self.recordFormat = targetFormat

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
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
                    }
                } else {
                    try file.write(from: buffer)
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
            "AudioRecorder started: %@ (in=%.0fHz/%dch → 16kHz/mono)",
            url.path,
            inputFormat.sampleRate,
            inputFormat.channelCount
        )
        return url
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .stopping

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        file = nil
        converter = nil
        recordFormat = nil
        lastRecordingURL = outputURL
        state = .idle
        NSLog("AudioRecorder stopped: \(lastRecordingURL?.path ?? "nil")")
    }

    private func resetEngineIfNeeded() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine.reset()
        engine = AVAudioEngine()
        converter = nil
        recordFormat = nil
    }

    private func cleanupAfterFailure() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        file = nil
        converter = nil
        recordFormat = nil
        outputURL = nil
        state = .idle
        engine.reset()
        engine = AVAudioEngine()
    }

    private func recorderError(_ message: String) -> NSError {
        NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
