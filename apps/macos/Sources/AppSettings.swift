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

    /// LLM polish provider: off / local / deepseek. Empty means migrate from legacy toggles.
    @AppStorage("llmPolishProvider") var llmPolishProviderRaw: String = ""
    /// Legacy toggle kept for one-time migration.
    @AppStorage("enableDeepSeekPostprocess") var enableDeepSeekPostprocess: Bool = false

    @AppStorage("deepSeekApiKey") var deepSeekApiKey: String = ""
    @AppStorage("deepSeekBaseURL") var deepSeekBaseURL: String = "https://api.deepseek.com"
    @AppStorage("deepSeekModel") var deepSeekModel: String = "deepseek-v4-flash"
    /// Seconds; on timeout/error fall back to pre-LLM text.
    @AppStorage("deepSeekTimeoutSeconds") var deepSeekTimeoutSeconds: Double = 8
    /// Prefer minimal edits when polishing.
    @AppStorage("deepSeekConservative") var deepSeekConservative: Bool = true

    @AppStorage("localLLMTimeoutSeconds") var localLLMTimeoutSeconds: Double = 30
    @AppStorage("localLLMConservative") var localLLMConservative: Bool = true

    /// Push-to-talk hardware key code. Default: right Option (61).
    @AppStorage("dictationHotkeyKeyCode") var dictationHotkeyKeyCode: Int = Int(DictationHotkey.defaultKeyCode)
    /// hold = press-and-hold; toggle = press to start, press again to stop.
    @AppStorage("dictationTriggerMode") var dictationTriggerModeRaw: String = DictationTriggerMode.hold.rawValue

    /// Ask AI hotkey. Default: F6.
    @AppStorage("askAIHotkeyKeyCode") var askAIHotkeyKeyCode: Int = Int(DictationHotkey.defaultAskKeyCode)
    @AppStorage("enableAskAI") var enableAskAI: Bool = true

    /// Local-only dictation history. Default off (privacy).
    @AppStorage("enableDictationHistory") var enableDictationHistory: Bool = false
    /// Keep history for this many days; 0 = until manually cleared.
    @AppStorage("historyRetentionDays") var historyRetentionDays: Int = 30
    /// After paste, detect manual edits and upsert into personal dictionary. Default on.
    @AppStorage("enableAutoDictionaryLearn") var enableAutoDictionaryLearn: Bool = true

    /// Unify Chinese output script. Default: simplified (SenseVoice/LLM may mix 简/繁).
    @AppStorage("chineseScript") var chineseScriptRaw: String = ChineseScriptPreference.simplified.rawValue

    var chineseScript: ChineseScriptPreference {
        get { ChineseScriptPreference(rawValue: chineseScriptRaw) ?? .simplified }
        set { chineseScriptRaw = newValue.rawValue }
    }

    var dictationHotkey: DictationHotkey {
        get {
            let code = UInt16(clamping: dictationHotkeyKeyCode)
            return DictationHotkey(keyCode: DictationHotkey.isAllowed(code) ? code : DictationHotkey.defaultKeyCode)
        }
        set {
            dictationHotkeyKeyCode = Int(newValue.keyCode)
        }
    }

    var askAIHotkey: DictationHotkey {
        get {
            let code = UInt16(clamping: askAIHotkeyKeyCode)
            return DictationHotkey(keyCode: DictationHotkey.isAllowed(code) ? code : DictationHotkey.defaultAskKeyCode)
        }
        set {
            askAIHotkeyKeyCode = Int(newValue.keyCode)
        }
    }

    var dictationTriggerMode: DictationTriggerMode {
        get { DictationTriggerMode(rawValue: dictationTriggerModeRaw) ?? .hold }
        set { dictationTriggerModeRaw = newValue.rawValue }
    }

    var llmPolishProvider: LLMPolishProvider {
        get {
            if llmPolishProviderRaw.isEmpty {
                return enableDeepSeekPostprocess ? .deepseek : .off
            }
            return LLMPolishProvider.resolve(stored: llmPolishProviderRaw)
        }
        set {
            llmPolishProviderRaw = newValue.rawValue
            enableDeepSeekPostprocess = (newValue == .deepseek)
        }
    }

    /// Call once at launch / settings open so legacy users keep their choice.
    func migrateLLMProviderIfNeeded() {
        if llmPolishProviderRaw == "ollama" {
            llmPolishProviderRaw = LLMPolishProvider.local.rawValue
            return
        }
        guard llmPolishProviderRaw.isEmpty else { return }
        llmPolishProviderRaw = enableDeepSeekPostprocess
            ? LLMPolishProvider.deepseek.rawValue
            : LLMPolishProvider.off.rawValue
    }

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

    var localLLMReady: Bool { LocalLLMAssets.isReady }
}
