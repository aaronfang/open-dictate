import AVFoundation

enum WavConverter {
    static func loadFloat32Mono16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "WavConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建音频缓冲区"])
        }
        try file.read(into: sourceBuffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(SenseVoiceConfig.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "WavConverter", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法创建目标音频格式"])
        }

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channelData = sourceBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channelData, count: Int(sourceBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(domain: "WavConverter", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法创建音频转换器"])
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let estimated = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio))
        var aggregated: [Float] = []
        aggregated.reserveCapacity(Int(estimated))

        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided {
                outStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        var error: NSError?
        let first = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(estimated, 1))!
        let firstStatus = converter.convert(to: first, error: &error, withInputFrom: inputBlock)
        if let error { throw error }
        guard firstStatus != .error else {
            throw NSError(domain: "WavConverter", code: -4, userInfo: [NSLocalizedDescriptionKey: "音频重采样失败"])
        }
        if first.frameLength > 0, let channelData = first.floatChannelData?[0] {
            aggregated.append(contentsOf: UnsafeBufferPointer(start: channelData, count: Int(first.frameLength)))
        }

        while true {
            let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
            let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
            if let error { throw error }
            guard status != .error else {
                throw NSError(domain: "WavConverter", code: -4, userInfo: [NSLocalizedDescriptionKey: "音频重采样失败"])
            }
            if out.frameLength > 0, let channelData = out.floatChannelData?[0] {
                aggregated.append(contentsOf: UnsafeBufferPointer(start: channelData, count: Int(out.frameLength)))
            }
            if status == .endOfStream { break }
        }

        guard !aggregated.isEmpty else {
            throw NSError(domain: "WavConverter", code: -5, userInfo: [NSLocalizedDescriptionKey: "转换后音频为空"])
        }
        return aggregated
    }

    /// Trim leading/trailing silence using adaptive energy VAD.
    static func trimSilence(
        _ samples: [Float],
        sampleRate: Int = SenseVoiceConfig.sampleRate,
        frameMs: Int = 30,
        padMs: Int = 200,
        rmsThreshold: Float = 0.01
    ) -> [Float] {
        _ = frameMs
        _ = padMs
        _ = rmsThreshold
        let trimmed = EnergyVAD.trimToSpeech(samples, sampleRate: sampleRate)
        // Fall back to original if VAD collapsed everything (very quiet speech).
        if trimmed.count < max(1, samples.count / 20), samples.count > sampleRate / 2 {
            return samples
        }
        return trimmed
    }

    /// Scale quiet waveforms toward the training distribution without clipping.
    static func peakNormalize(_ samples: [Float], targetPeak: Float = 0.9) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 1e-8, peak < targetPeak else {
            return samples
        }
        let gain = targetPeak / peak
        return samples.map { $0 * gain }
    }

    /// Peak absolute amplitude in [-1, 1] range.
    static func peakAmplitude(_ samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
    }

    /// True when the clip is likely silence / mic bump with no speech.
    static func looksLikeSilence(
        _ samples: [Float],
        sampleRate: Int = SenseVoiceConfig.sampleRate,
        minDurationSeconds: Double = 0.35,
        minPeak: Float = 0.02
    ) -> Bool {
        _ = minDurationSeconds
        _ = minPeak
        return EnergyVAD.looksLikeSilence(samples, sampleRate: sampleRate)
    }
}
