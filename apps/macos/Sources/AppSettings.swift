import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("sttEngine") var sttEngineRaw: String = STTEngine.senseVoice.rawValue
    @AppStorage("senseVoiceModelsPath") var senseVoiceModelsPath: String = SenseVoiceConfig.defaultModelsDirectory
    @AppStorage("senseVoiceUseInt8") var senseVoiceUseInt8: Bool = true
    @AppStorage("senseVoiceUseFp32") var senseVoiceUseFp32: Bool = false
    /// SenseVoice language: zh (default) / auto / en / yue / ja / ko
    @AppStorage("senseVoiceLanguage") var senseVoiceLanguage: String = "zh"
    /// Inverse text normalization: punctuation + number formatting (SenseVoice withitn).
    @AppStorage("senseVoiceEnableITN") var senseVoiceEnableITN: Bool = true

    @AppStorage("whisperBinary") var whisperBinary: String = "/opt/homebrew/bin/whisper-cli"
    @AppStorage("whisperModelPath") var whisperModelPath: String = "/Users/aaronfang/Documents/github/open-dictate/models/ggml-base.bin"
    @AppStorage("whisperLanguage") var whisperLanguage: String = "auto"
    @AppStorage("storePath") var storePath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("OpenDictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("open_dictate.sqlite3").path
    }()

    /// Rule-based post-process (filler removal + whitespace normalize). Default on.
    @AppStorage("enableRulesPostprocess") var enableRulesPostprocess: Bool = true

    /// Optional DeepSeek cloud polish (text only). Default off — local-first.
    @AppStorage("enableDeepSeekPostprocess") var enableDeepSeekPostprocess: Bool = false
    @AppStorage("deepSeekApiKey") var deepSeekApiKey: String = ""
    @AppStorage("deepSeekBaseURL") var deepSeekBaseURL: String = "https://api.deepseek.com"
    @AppStorage("deepSeekModel") var deepSeekModel: String = "deepseek-v4-flash"
    /// Seconds; on timeout/error fall back to pre-LLM text.
    @AppStorage("deepSeekTimeoutSeconds") var deepSeekTimeoutSeconds: Double = 8
    /// Prefer minimal edits when polishing.
    @AppStorage("deepSeekConservative") var deepSeekConservative: Bool = true

    var deepSeekConfigured: Bool {
        !deepSeekApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var deepSeekConfig: DeepSeekPostProcessor.Config {
        DeepSeekPostProcessor.Config(
            apiKey: deepSeekApiKey,
            baseURL: deepSeekBaseURL,
            model: deepSeekModel,
            timeoutSeconds: deepSeekTimeoutSeconds,
            conservative: deepSeekConservative
        )
    }

    var sttEngine: STTEngine {
        get { STTEngine(rawValue: sttEngineRaw) ?? .senseVoice }
        set { sttEngineRaw = newValue.rawValue }
    }

    var senseVoiceModelsReady: Bool {
        let base = URL(fileURLWithPath: NSString(string: senseVoiceModelsPath).expandingTildeInPath)
        let encoderName = senseVoiceUseFp32
            ? "SenseVoiceSmall_fp32.mlmodelc"
            : (senseVoiceUseInt8 ? "SenseVoiceSmall_int8.mlmodelc" : "SenseVoiceSmall.mlmodelc")
        let paths = [
            base.appendingPathComponent("SenseVoicePreprocessor.mlmodelc").path,
            base.appendingPathComponent(encoderName).path,
            base.appendingPathComponent("vocab.json").path,
        ]
        return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
}
