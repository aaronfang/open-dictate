import CoreML
import Foundation

enum SenseVoiceCoreMLError: LocalizedError {
    case modelNotFound(String)
    case inferenceFailed(String)
    case emptyResult
    case noSpeech
    case rejectedGarbage(String)

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
        _ = try runEncoder(features: features)
    }

    func transcribe(wavURL: URL) throws -> String {
        var audio = try WavConverter.loadFloat32Mono16k(url: wavURL)
        let rawCount = audio.count
        audio = WavConverter.trimSilence(audio)
        audio = WavConverter.peakNormalize(audio)
        NSLog(
            "SenseVoice: audio frames raw=%d trimmed=%d (%.2fs @16k)",
            rawCount,
            audio.count,
            Double(audio.count) / Double(SenseVoiceConfig.sampleRate)
        )

        do {
            return try transcribe(waveformFloat32: audio)
        } catch SenseVoiceCoreMLError.emptyResult, SenseVoiceCoreMLError.noSpeech {
            // Retry 1: refresh ANE after long idle.
            NSLog("SenseVoice: empty/nospeech — re-warmup and retry")
            try warmup()
            do {
                return try transcribe(waveformFloat32: audio)
            } catch SenseVoiceCoreMLError.emptyResult, SenseVoiceCoreMLError.noSpeech {
                // Retry 2: without peak-normalize (quiet room + normalize can hurt).
                NSLog("SenseVoice: retry without peakNormalize")
                var rawAudio = try WavConverter.loadFloat32Mono16k(url: wavURL)
                rawAudio = WavConverter.trimSilence(rawAudio)
                return try transcribe(waveformFloat32: rawAudio)
            }
        }
    }

    func transcribe(waveformFloat32 audio: [Float]) throws -> String {
        guard !audio.isEmpty else {
            throw SenseVoiceCoreMLError.emptyResult
        }

        let features = try runPreprocessor(audio: audio)
        let (logits, validFrames) = try runEncoder(features: features)
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
        return decoded.text
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

    private func runEncoder(features: MLMultiArray) throws -> (MLMultiArray, Int) {
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
