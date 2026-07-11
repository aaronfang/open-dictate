import CoreML
import Foundation

enum SenseVoiceCoreMLError: LocalizedError {
    case modelNotFound(String)
    case inferenceFailed(String)
    case emptyResult
    case noSpeech
    case rejectedGarbage(String)
    /// All attempts were sparse/unreliable; associated text is the best weak candidate.
    case weakResult(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "找不到 SenseVoice 模型：\(path)"
        case .inferenceFailed(let message):
            return message
        case .emptyResult:
            return "SenseVoice 识别结果为空"
        case .noSpeech:
            return "SenseVoice 未检测到有效语音"
        case .rejectedGarbage(let text):
            return "SenseVoice 结果异常已丢弃（\(text)）"
        case .weakResult(let text):
            return "SenseVoice 结果不可靠（\(text)）"
        }
    }
}

final class SenseVoiceCoreMLProvider {
    struct Config {
        var modelsDirectory: URL
        var useInt8Encoder: Bool = true
        var useFp32Encoder: Bool = false
        var language: Int32 = SenseVoiceConfig.defaultLanguage
        var textNorm: Int32 = SenseVoiceConfig.defaultTextNorm
    }

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let vocabulary: [String]
    private let language: Int32
    private let textNorm: Int32
    private let useFp32Encoder: Bool

    init(config: Config) throws {
        let base = config.modelsDirectory
        let preprocessorURL = base.appendingPathComponent("SenseVoicePreprocessor.mlmodelc", isDirectory: true)
        let encoderName: String
        if config.useFp32Encoder {
            encoderName = "SenseVoiceSmall_fp32.mlmodelc"
        } else if config.useInt8Encoder {
            encoderName = "SenseVoiceSmall_int8.mlmodelc"
        } else {
            encoderName = "SenseVoiceSmall.mlmodelc"
        }
        let encoderURL = base.appendingPathComponent(encoderName, isDirectory: true)
        let vocabURL = base.appendingPathComponent("vocab.json")

        guard FileManager.default.fileExists(atPath: preprocessorURL.path) else {
            throw SenseVoiceCoreMLError.modelNotFound(preprocessorURL.path)
        }
        guard FileManager.default.fileExists(atPath: encoderURL.path) else {
            throw SenseVoiceCoreMLError.modelNotFound(encoderURL.path)
        }
        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw SenseVoiceCoreMLError.modelNotFound(vocabURL.path)
        }

        let preCfg = MLModelConfiguration()
        preCfg.computeUnits = .cpuOnly

        let encCfg = MLModelConfiguration()
        encCfg.computeUnits = config.useFp32Encoder ? .all : .cpuAndNeuralEngine
        if #available(macOS 14.4, *) {
            // Enumerated frame buckets: prefer stable shapes over fast reshape switching.
            var hints = MLOptimizationHints()
            hints.reshapeFrequency = .infrequent
            encCfg.optimizationHints = hints
        }

        NSLog(
            "SenseVoice: loading preprocessor + encoder (%@)…",
            config.useFp32Encoder ? "fp32" : (config.useInt8Encoder ? "int8" : "fp16")
        )
        let loadStarted = CFAbsoluteTimeGetCurrent()

        var loadedPreprocessor: MLModel?
        var loadedEncoder: MLModel?
        var loadError: Error?
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                loadedPreprocessor = try MLModel(contentsOf: preprocessorURL, configuration: preCfg)
            } catch {
                loadError = error
            }
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                loadedEncoder = try MLModel(contentsOf: encoderURL, configuration: encCfg)
            } catch {
                loadError = error
            }
        }

        group.wait()
        if let loadError { throw loadError }
        guard let loadedPreprocessor, let loadedEncoder else {
            throw SenseVoiceCoreMLError.inferenceFailed("模型加载失败")
        }
        preprocessor = loadedPreprocessor
        encoder = loadedEncoder
        NSLog("SenseVoice: models ready in %.1fs", CFAbsoluteTimeGetCurrent() - loadStarted)

        let data = try Data(contentsOf: vocabURL)
        vocabulary = try JSONDecoder().decode([String].self, from: data)
        language = config.language
        textNorm = config.textNorm
        useFp32Encoder = config.useFp32Encoder
    }

    /// Run a minimal inference to compile/warm the ANE path before the first real utterance.
    func warmup() throws {
        let samples = [Float](repeating: 0, count: 8_000)
        let features = try runPreprocessor(audio: samples)
        _ = try runEncoder(features: features, language: language, textNorm: textNorm)
    }

    func transcribe(wavURL: URL) throws -> String {
        let audio = try WavConverter.loadFloat32Mono16k(url: wavURL)
        let rawCount = audio.count
        let trimmed = WavConverter.trimSilence(audio)
        let normalized = WavConverter.peakNormalize(trimmed)
        NSLog(
            "SenseVoice: audio frames raw=%d trimmed=%d (%.2fs @16k)",
            rawCount,
            trimmed.count,
            Double(trimmed.count) / Double(SenseVoiceConfig.sampleRate)
        )

        if trimmed.count > SenseVoiceConfig.maxWaveformSamples {
            return try transcribeLongAudio(normalized: normalized, trimmed: trimmed)
        }

        return try transcribeWithRetries(normalized: normalized, trimmed: trimmed, raw: audio)
    }

    /// Split audio longer than the CoreML 30s waveform limit into overlapping chunks.
    private func transcribeLongAudio(normalized: [Float], trimmed: [Float]) throws -> String {
        let source = normalized.count >= SenseVoiceConfig.minWaveformSamples ? normalized : trimmed
        let chunks = Self.splitWaveform(
            source,
            chunkSamples: SenseVoiceConfig.chunkWaveformSamples,
            overlapSamples: SenseVoiceConfig.chunkOverlapSamples
        )
        NSLog(
            "SenseVoice: long audio %.1fs exceeds %.0fs limit — %d chunks",
            Double(source.count) / Double(SenseVoiceConfig.sampleRate),
            Double(SenseVoiceConfig.maxWaveformSamples) / Double(SenseVoiceConfig.sampleRate),
            chunks.count
        )

        var parts: [String] = []
        var lastError: Error = SenseVoiceCoreMLError.noSpeech
        for (index, chunk) in chunks.enumerated() {
            NSLog(
                "SenseVoice: chunk %d/%d (%.1fs)",
                index + 1,
                chunks.count,
                Double(chunk.count) / Double(SenseVoiceConfig.sampleRate)
            )
            do {
                let text = try transcribeSingleChunk(chunk)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(text)
                }
            } catch let error as SenseVoiceCoreMLError {
                switch error {
                case .noSpeech, .emptyResult:
                    lastError = error
                    continue
                default:
                    throw error
                }
            } catch {
                lastError = error
                // CoreML shape errors should not happen after chunking; surface clearly.
                if Self.isWaveformLengthError(error) {
                    throw SenseVoiceCoreMLError.inferenceFailed(
                        "音频分段后仍超长，请缩短单次听写（最长约 30 秒/段）"
                    )
                }
                throw error
            }
        }

        let joined = Self.joinTranscriptParts(parts)
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw lastError
        }
        NSLog("SenseVoice: long audio joined parts=%d text=%@", parts.count, joined)
        return joined
    }

    private func transcribeSingleChunk(_ samples: [Float]) throws -> String {
        do {
            return try transcribe(waveformFloat32: samples)
        } catch let error as SenseVoiceCoreMLError {
            switch error {
            case .noSpeech, .emptyResult:
                return try transcribe(
                    waveformFloat32: samples,
                    textNormOverride: SenseVoiceConfig.textNormEmbedIndex(enableITN: false)
                )
            default:
                throw error
            }
        }
    }

    private func transcribeWithRetries(normalized: [Float], trimmed: [Float], raw: [Float]) throws -> String {
        let attempts: [(label: String, samples: [Float], language: Int32?, textNorm: Int32?)] = [
            ("peakNorm", normalized, nil, nil),
            ("woitn+peakNorm", normalized, nil, SenseVoiceConfig.textNormEmbedIndex(enableITN: false)),
            ("noPeakNorm", trimmed, nil, nil),
            ("woitn", trimmed, nil, SenseVoiceConfig.textNormEmbedIndex(enableITN: false)),
            ("auto+woitn", trimmed, SenseVoiceConfig.languageEmbedIndex("auto"), SenseVoiceConfig.textNormEmbedIndex(enableITN: false)),
            // Prefer ITN on raw audio when trimmed paths fail — restores commas/periods.
            ("rawNoTrim+itn", raw, nil, SenseVoiceConfig.textNormEmbedIndex(enableITN: true)),
            // rawNoTrim woitn often hallucinates on leading/trailing silence — last resort only.
            ("rawNoTrim", raw, nil, SenseVoiceConfig.textNormEmbedIndex(enableITN: false)),
        ]

        var lastError: Error = SenseVoiceCoreMLError.noSpeech
        var weakCandidates: [(label: String, text: String)] = []

        for (index, attempt) in attempts.enumerated() {
            if index > 0 {
                NSLog("SenseVoice: retry \(attempt.label)")
            }
            do {
                let text = try transcribe(
                    waveformFloat32: attempt.samples,
                    languageOverride: attempt.language,
                    textNormOverride: attempt.textNorm
                )
                let seconds = Double(attempt.samples.count) / Double(SenseVoiceConfig.sampleRate)
                let weak = attempt.label == "rawNoTrim" || Self.isWeakTranscript(text, audioSeconds: seconds)
                if weak {
                    NSLog(
                        "SenseVoice: weak candidate %@ (%.1fs, chars=%d): %@",
                        attempt.label,
                        seconds,
                        Self.contentCharacterCount(text),
                        text
                    )
                    weakCandidates.append((attempt.label, text))
                    continue
                }
                return text
            } catch let error as SenseVoiceCoreMLError {
                switch error {
                case .noSpeech, .emptyResult:
                    lastError = error
                    continue
                default:
                    throw error
                }
            } catch {
                if Self.isWaveformLengthError(error) {
                    NSLog("SenseVoice: waveform length error on short path — chunking")
                    return try transcribeLongAudio(normalized: normalized, trimmed: trimmed)
                }
                throw SenseVoiceCoreMLError.inferenceFailed(error.localizedDescription)
            }
        }

        // Only weak / rawNoTrim results: hand off to whisper (keep best weak as fallback).
        if let best = weakCandidates.max(by: {
            Self.contentCharacterCount($0.text) < Self.contentCharacterCount($1.text)
        }) {
            NSLog(
                "SenseVoice: no strong candidate — weak %@ → %@",
                best.label,
                best.text
            )
            throw SenseVoiceCoreMLError.weakResult(best.text)
        }
        throw lastError
    }

    private static func splitWaveform(_ samples: [Float], chunkSamples: Int, overlapSamples: Int) -> [[Float]] {
        let maxLen = min(chunkSamples, SenseVoiceConfig.maxWaveformSamples)
        guard samples.count > maxLen else { return [samples] }

        let step = max(1, maxLen - max(0, overlapSamples))
        var chunks: [[Float]] = []
        var start = 0
        while start < samples.count {
            let end = min(start + maxLen, samples.count)
            let slice = Array(samples[start..<end])
            if slice.count >= SenseVoiceConfig.minWaveformSamples {
                chunks.append(slice)
            } else if let last = chunks.last {
                // Merge a tiny tail into the previous chunk when possible.
                let merged = last + slice
                if merged.count <= SenseVoiceConfig.maxWaveformSamples {
                    chunks[chunks.count - 1] = merged
                } else {
                    chunks.append(Array(slice.suffix(SenseVoiceConfig.minWaveformSamples)))
                }
            }
            if end >= samples.count { break }
            start += step
        }
        return chunks.isEmpty ? [samples] : chunks
    }

    private static func joinTranscriptParts(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "")
    }

    private static func isWaveformLengthError(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return message.contains("allowed range")
            || message.contains("480000")
            || message.contains("dimension (1)")
    }

    func transcribe(
        waveformFloat32 audio: [Float],
        languageOverride: Int32? = nil,
        textNormOverride: Int32? = nil
    ) throws -> String {
        guard !audio.isEmpty else {
            throw SenseVoiceCoreMLError.emptyResult
        }
        if audio.count > SenseVoiceConfig.maxWaveformSamples {
            throw SenseVoiceCoreMLError.inferenceFailed(
                "单段音频过长（\(String(format: "%.1f", Double(audio.count) / Double(SenseVoiceConfig.sampleRate)))s），上限约 30 秒"
            )
        }

        let features = try runPreprocessor(audio: audio)
        let (logits, validFrames) = try runEncoder(
            features: features,
            language: languageOverride ?? language,
            textNorm: textNormOverride ?? textNorm
        )
        let decoded = decode(logits: logits, validFrames: validFrames)
        NSLog(
            "SenseVoice: decode raw=%@ text=%@ nospeech=%@ garbage=%@",
            decoded.raw,
            decoded.text,
            decoded.isNoSpeech ? "yes" : "no",
            decoded.isGarbage ? "yes" : "no"
        )
        if decoded.isGarbage {
            throw SenseVoiceCoreMLError.rejectedGarbage(decoded.text.isEmpty ? decoded.raw : decoded.text)
        }
        if decoded.isNoSpeech {
            throw SenseVoiceCoreMLError.noSpeech
        }
        if decoded.text.isEmpty || Self.isPunctuationOnly(decoded.text) {
            NSLog("SenseVoice: treating punctuation-only as empty: \(decoded.text)")
            throw SenseVoiceCoreMLError.noSpeech
        }
        let seconds = Double(audio.count) / Double(SenseVoiceConfig.sampleRate)
        // Only reject near-empty transcripts here. Density checks happen in the retry
        // loop so we can keep weak candidates and still fall back to whisper.
        if Self.isNearEmptyTranscript(decoded.text, audioSeconds: seconds) {
            NSLog(
                "SenseVoice: treating near-empty result as empty: \"%@\" for %.1fs audio",
                decoded.text,
                seconds
            )
            throw SenseVoiceCoreMLError.noSpeech
        }
        return decoded.text
    }

    /// Truly empty-ish results only (avoid discarding usable partials).
    private static func isNearEmptyTranscript(_ text: String, audioSeconds: Double) -> Bool {
        let n = contentCharacterCount(text)
        if n == 0 { return true }
        if audioSeconds >= 3, n < 2 { return true }
        if audioSeconds >= 8, n < 4 { return true }
        return false
    }

    static func contentCharacterCount(_ text: String) -> Int {
        text.filter { ch in
            !ch.isWhitespace && !ch.isPunctuation && !ch.isNewline
        }.count
    }

    /// Sparse vs duration — often a failed / hallucinated decode.
    static func isWeakTranscript(_ text: String, audioSeconds: Double) -> Bool {
        let n = contentCharacterCount(text)
        if n < 2 { return true }
        if audioSeconds >= 5.0, Double(n) < audioSeconds * 2.2 { return true }
        if audioSeconds >= 7.0, Double(n) < audioSeconds * 1.8 { return true }
        return false
    }

    static func pickBetterTranscript(_ a: String, _ b: String) -> String {
        let ca = contentCharacterCount(a)
        let cb = contentCharacterCount(b)
        let pa = punctuationCount(a)
        let pb = punctuationCount(b)

        // Similar content: prefer the one with punctuation (ITN / whisper).
        if abs(ca - cb) <= 4, pa != pb {
            return pb > pa ? b : a
        }
        if cb >= ca + 3 { return b }
        if ca >= cb + 3 { return a }
        if pb > pa { return b }
        if pa > pb { return a }
        return ca >= cb ? a : b
    }

    private static func punctuationCount(_ text: String) -> Int {
        text.filter { "，。？！、；：,.".contains($0) }.count
    }

    /// "。" / "…" / mixed punctuation with no real content — common withitn on silence.
    private static func isPunctuationOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private func runPreprocessor(audio: [Float]) throws -> MLMultiArray {
        let waveform = try MLMultiArray(shape: [1, audio.count as NSNumber], dataType: .float32)
        let wptr = waveform.dataPointer.assumingMemoryBound(to: Float32.self)
        let scale = SenseVoiceConfig.waveformScale
        for i in 0..<audio.count {
            wptr[i] = audio[i] * scale
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "waveform": MLFeatureValue(multiArray: waveform),
        ])
        let output = try preprocessor.prediction(from: input)
        guard let features = output.featureValue(for: "features")?.multiArrayValue else {
            throw SenseVoiceCoreMLError.inferenceFailed("Preprocessor 未返回 features")
        }
        return features
    }

    private func runEncoder(
        features: MLMultiArray,
        language: Int32,
        textNorm: Int32
    ) throws -> (MLMultiArray, Int) {
        var frameCount = features.shape[1].intValue
        if frameCount > SenseVoiceConfig.maxFrames {
            frameCount = SenseVoiceConfig.maxFrames
        }
        // FP32 导出固定 1800 帧 bucket；FP16/INT8 使用枚举 bucket。
        let bucket = useFp32Encoder
            ? SenseVoiceConfig.maxFrames
            : SenseVoiceConfig.pickBucket(forFrames: frameCount)
        let dim = SenseVoiceConfig.featureDim

        let speech = try MLMultiArray(shape: [1, bucket as NSNumber, dim as NSNumber], dataType: .float32)
        let sptr = speech.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(sptr, 0, bucket * dim * MemoryLayout<Float32>.size)

        // Copy with stride awareness — preprocessor output may not be tightly packed.
        let featureCount = min(frameCount, features.shape[1].intValue)
        let src = features
        let srcStrides = src.strides.map(\.intValue)
        let dstStrideT = speech.strides[1].intValue
        let dstStrideD = speech.strides[2].intValue
        if src.dataType == .float32,
           srcStrides.count >= 3,
           srcStrides[2] == 1,
           dstStrideD == 1 {
            let sp = src.dataPointer.assumingMemoryBound(to: Float32.self)
            for t in 0..<featureCount {
                let srcOff = t * srcStrides[1]
                let dstOff = t * dstStrideT
                memcpy(sptr.advanced(by: dstOff), sp.advanced(by: srcOff), dim * MemoryLayout<Float32>.size)
            }
        } else {
            for t in 0..<featureCount {
                for d in 0..<dim {
                    speech[[0, t as NSNumber, d as NSNumber]] = src[[0, t as NSNumber, d as NSNumber]]
                }
            }
        }

        NSLog(
            "SenseVoice: encoder frames=%d bucket=%d logits_prep featureDim=%d",
            featureCount,
            bucket,
            dim
        )

        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: featureCount)

        let languageArray = try MLMultiArray(shape: [1], dataType: .int32)
        languageArray[0] = NSNumber(value: language)

        let textNormArray = try MLMultiArray(shape: [1], dataType: .int32)
        textNormArray[0] = NSNumber(value: textNorm)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: lengths),
            "language": MLFeatureValue(multiArray: languageArray),
            "textnorm": MLFeatureValue(multiArray: textNormArray),
        ])

        let output = try encoder.prediction(from: input)
        guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw SenseVoiceCoreMLError.inferenceFailed("Encoder 未返回 ctc_logits")
        }

        return (logits, SenseVoiceConfig.numQueryTokens + frameCount)
    }

    private struct Decoded {
        var raw: String
        var text: String
        var isNoSpeech: Bool
        var isGarbage: Bool
    }

    /// Returns cleaned transcript plus diagnostics.
    private func decode(logits: MLMultiArray, validFrames: Int) -> Decoded {
        let vocabSize = logits.shape[2].intValue
        let frames = min(validFrames, logits.shape[1].intValue)
        let strides = logits.strides.map(\.intValue)
        let strideT = strides.count > 1 ? strides[1] : vocabSize
        let strideV = strides.count > 2 ? strides[2] : 1
        var tokenIds: [Int] = []
        var previous = -1
        var nanFrames = 0

        func appendArgmax(frameBase: (Int) -> Float) {
            var best = 0
            var bestValue = frameBase(0)
            if bestValue.isNaN { nanFrames += 1 }
            for index in 1..<vocabSize {
                let value = frameBase(index)
                if value > bestValue {
                    bestValue = value
                    best = index
                }
            }
            if best != SenseVoiceConfig.blankId, best != previous {
                tokenIds.append(best)
            }
            previous = best
        }

        if logits.dataType == .float32 {
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for frame in 0..<frames {
                let base = frame * strideT
                appendArgmax { pointer[base + $0 * strideV] }
            }
        } else if logits.dataType == .float16 {
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            for frame in 0..<frames {
                let base = frame * strideT
                appendArgmax { Float(pointer[base + $0 * strideV]) }
            }
        } else {
            for frame in 0..<frames {
                appendArgmax { logits[[0, frame as NSNumber, $0 as NSNumber]].floatValue }
            }
        }

        let raw = tokenIds.compactMap { index -> String? in
            guard index >= 0, index < vocabulary.count else { return nil }
            return vocabulary[index]
        }.joined()

        NSLog(
            "SenseVoice: ctc tokens=%d non_special=%d logitsType=%d framesDecoded=%d nanFrames=%d strideT=%d strideV=%d",
            tokenIds.count,
            tokenIds.filter { $0 < 24884 }.count,
            logits.dataType.rawValue,
            frames,
            nanFrames,
            strideT,
            strideV
        )

        let isNoSpeech = raw.contains("<|nospeech|>")
        let text = raw
            .replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // When forced to Chinese, reject obvious wrong-script garbage (e.g. lone Hangul "그").
        let isGarbage = language == 3 && Self.looksLikeWrongScriptGarbage(text)
        if isGarbage {
            NSLog("SenseVoice: dropping wrong-script garbage: \(text)")
        }

        return Decoded(raw: raw, text: text, isNoSpeech: isNoSpeech, isGarbage: isGarbage)
    }

    /// Short Hangul/Kana-only output with no Han/Latin — typical auto-LID misfire.
    private static func looksLikeWrongScriptGarbage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4 else { return false }

        var hasHangulOrKana = false
        var hasHanOrLatin = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            let v = scalar.value
            let hangul = (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0x1100 && v <= 0x11FF)
            let kana = (v >= 0x3040 && v <= 0x30FF)
            let han = (v >= 0x4E00 && v <= 0x9FFF)
            let latin = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            if hangul || kana { hasHangulOrKana = true }
            if han || latin { hasHanOrLatin = true }
        }
        return hasHangulOrKana && !hasHanOrLatin
    }
}
