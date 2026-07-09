import AVFoundation

final class AudioRecorder {
    enum State {
        case idle
        case recording
        case stopping
    }

    private(set) var state: State = .idle
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var outputURL: URL?

    func startRecording() throws -> URL {
        guard state == .idle else { return outputURL ?? URL(fileURLWithPath: "/dev/null") }
        state = .recording

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // 目标格式：16kHz mono i16 wav（方便对接 whisper.cpp）
        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }

        let temp = FileManager.default.temporaryDirectory
        let url = temp.appendingPathComponent("open_dictate_\(UUID().uuidString).wav")
        outputURL = url

        file = try AVAudioFile(forWriting: url, settings: desiredFormat.settings)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard self.state == .recording, let file = self.file else { return }

            if let converted = self.convert(buffer: buffer, to: desiredFormat) {
                do {
                    try file.write(from: converted)
                } catch {
                    NSLog("AudioRecorder write error: \(error)")
                }
            }
        }

        engine.prepare()
        try engine.start()
        return url
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .stopping

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        state = .idle
    }

    private func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        if let error {
            NSLog("AudioRecorder convert error: \(error)")
            return nil
        }
        return out
    }
}

