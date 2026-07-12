import Foundation

/// Lightweight energy-based VAD for dictation (no WebRTC dependency).
enum EnergyVAD {
    struct Analysis: Equatable {
        let speechFrameCount: Int
        let totalFrameCount: Int
        let speechDurationSeconds: Double
        let peak: Float
        let noiseFloor: Float
        let speechStartSample: Int?
        let speechEndSample: Int?
    }

    /// Estimate ambient noise from the quietest early frames (or global quiet percentile).
    static func noiseFloor(
        _ samples: [Float],
        sampleRate: Int = SenseVoiceConfig.sampleRate,
        frameMs: Int = 30,
        probeMs: Int = 300
    ) -> Float {
        guard !samples.isEmpty else { return 0.01 }
        let frameLen = max(1, sampleRate * frameMs / 1000)
        let probeFrames = max(1, (sampleRate * probeMs / 1000) / frameLen)
        var rmsValues: [Float] = []
        rmsValues.reserveCapacity(probeFrames + 4)

        var offset = 0
        var seen = 0
        while offset + frameLen <= samples.count, seen < max(probeFrames, 8) {
            rmsValues.append(sqrt(framePower(samples, offset: offset, length: frameLen)))
            offset += frameLen
            seen += 1
        }
        // Also sample a few frames across the whole clip for noise-heavy rooms.
        offset = 0
        while offset + frameLen <= samples.count {
            rmsValues.append(sqrt(framePower(samples, offset: offset, length: frameLen)))
            offset += frameLen * 8
            if rmsValues.count > 64 { break }
        }
        guard !rmsValues.isEmpty else { return 0.01 }
        rmsValues.sort()
        let idx = min(rmsValues.count - 1, max(0, rmsValues.count / 5)) // ~20th percentile
        return max(0.003, rmsValues[idx])
    }

    static func analyze(
        _ samples: [Float],
        sampleRate: Int = SenseVoiceConfig.sampleRate,
        frameMs: Int = 30,
        padMs: Int = 180
    ) -> Analysis {
        guard !samples.isEmpty else {
            return Analysis(
                speechFrameCount: 0,
                totalFrameCount: 0,
                speechDurationSeconds: 0,
                peak: 0,
                noiseFloor: 0.01,
                speechStartSample: nil,
                speechEndSample: nil
            )
        }

        let frameLen = max(1, sampleRate * frameMs / 1000)
        let pad = sampleRate * padMs / 1000
        let floor = noiseFloor(samples, sampleRate: sampleRate, frameMs: frameMs)
        let threshold = max(0.012, floor * 2.8)
        let threshSq = threshold * threshold
        let peak = samples.map { abs($0) }.max() ?? 0

        var speechFrames = 0
        var totalFrames = 0
        var firstSpeechOffset: Int?
        var lastSpeechOffset: Int?

        var offset = 0
        while offset + frameLen <= samples.count {
            let power = framePower(samples, offset: offset, length: frameLen)
            totalFrames += 1
            if power > threshSq {
                speechFrames += 1
                if firstSpeechOffset == nil { firstSpeechOffset = offset }
                lastSpeechOffset = offset
            }
            offset += frameLen
        }

        let start: Int? = firstSpeechOffset.map { max(0, $0 - pad) }
        let end: Int? = lastSpeechOffset.map { min(samples.count, $0 + frameLen + pad) }
        let speechDuration = Double(speechFrames * frameLen) / Double(sampleRate)

        return Analysis(
            speechFrameCount: speechFrames,
            totalFrameCount: totalFrames,
            speechDurationSeconds: speechDuration,
            peak: peak,
            noiseFloor: floor,
            speechStartSample: start,
            speechEndSample: end
        )
    }

    /// True when there is too little sustained speech energy (mic bump / noise only).
    static func looksLikeSilence(
        _ samples: [Float],
        sampleRate: Int = SenseVoiceConfig.sampleRate,
        minSpeechSeconds: Double = 0.22,
        minPeak: Float = 0.018
    ) -> Bool {
        let duration = Double(samples.count) / Double(sampleRate)
        if duration < 0.28 { return true }
        let a = analyze(samples, sampleRate: sampleRate)
        if a.peak < minPeak { return true }
        if a.speechDurationSeconds < minSpeechSeconds { return true }
        // Mostly noise floor with isolated spikes.
        if a.totalFrameCount > 0 {
            let ratio = Double(a.speechFrameCount) / Double(a.totalFrameCount)
            if ratio < 0.08, a.speechDurationSeconds < 0.4 { return true }
        }
        return false
    }

    static func trimToSpeech(
        _ samples: [Float],
        sampleRate: Int = SenseVoiceConfig.sampleRate
    ) -> [Float] {
        let a = analyze(samples, sampleRate: sampleRate)
        guard let start = a.speechStartSample, let end = a.speechEndSample, end > start else {
            return samples
        }
        return Array(samples[start..<end])
    }

    /// RMS of a mono float buffer (for live tap analysis).
    static func rms(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let v = samples[i]
            sum += v * v
        }
        return sqrt(sum / Float(count))
    }

    private static func framePower(_ samples: [Float], offset: Int, length: Int) -> Float {
        let end = min(offset + length, samples.count)
        guard end > offset else { return 0 }
        var sum: Float = 0
        for i in offset..<end {
            let v = samples[i]
            sum += v * v
        }
        return sum / Float(end - offset)
    }
}
