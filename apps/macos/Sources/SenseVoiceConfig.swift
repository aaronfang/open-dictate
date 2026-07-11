import Foundation

extension Notification.Name {
    static let senseVoiceLoadStarted = Notification.Name("SenseVoiceLoadStarted")
    static let senseVoiceLoaded = Notification.Name("SenseVoiceLoaded")
    static let senseVoiceWarmedUp = Notification.Name("SenseVoiceWarmedUp")
    static let senseVoiceLoadFailed = Notification.Name("SenseVoiceLoadFailed")
}

enum SenseVoiceConfig {
    static let sampleRate = 16_000
    static let waveformScale: Float = 32_768
    static let featureDim = 560
    static let blankId = 0
    static let numQueryTokens = 4
    static let buckets = [128, 256, 512, 1024, 1800]

    /// CoreML preprocessor waveform length constraints (samples @ 16 kHz).
    static let minWaveformSamples = 3_200 // 0.2s
    static let maxWaveformSamples = 480_000 // 30s
    /// Chunk size for long dictation (leave headroom under max).
    static let chunkWaveformSamples = 28 * sampleRate // 28s
    static let chunkOverlapSamples = sampleRate / 2 // 0.5s

    /// FunASR lid embed: auto=0, zh=3, en=4, yue=7, ja=11, ko=12, nospeech=13
    static let defaultLanguage: Int32 = 3
    /// 14 = withitn（标点/数字归一化），15 = woitn（纯文本）
    static let defaultTextNorm: Int32 = 14

    static var maxFrames: Int { buckets.last ?? 1800 }

    static func pickBucket(forFrames frames: Int) -> Int {
        for bucket in buckets where bucket >= frames {
            return bucket
        }
        return buckets.last ?? 1800
    }

    static func textNormEmbedIndex(enableITN: Bool) -> Int32 {
        enableITN ? 14 : 15
    }

    /// Map UI / settings language code → SenseVoice embed index.
    static func languageEmbedIndex(_ code: String) -> Int32 {
        switch code.lowercased() {
        case "auto": return 0
        case "zh", "zh-cn", "zh_cn", "chinese": return 3
        case "en", "english": return 4
        case "yue", "cantonese": return 7
        case "ja", "jp", "japanese": return 11
        case "ko", "korean": return 12
        default: return 3
        }
    }

    static var defaultModelsDirectory: String {
        "/Users/aaronfang/Documents/github/open-dictate/models/sensevoice"
    }
}
