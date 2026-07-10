import Foundation

enum TextIntelligence {
    /// Filler list tightened vs Core: omit 就是 / 然后 (too easy to false-positive).
    private static let fillerWords: [String] = [
        "um", "uh", "you know", "like",
        "额", "嗯", "呃", "你知道",
    ]

    struct ProcessResult {
        let text: String
        /// Resolved per-app tone for LLM style hint.
        let tone: String?
        let appId: String?
        let profileApplied: Bool
        let llmApplied: Bool
        let llmProvider: LLMPolishProvider
    }

    /// Dictionary → rules → optional LLM → app-profile format.
    static func process(
        _ raw: String,
        settings: AppSettings,
        appId: String? = nil
    ) async -> ProcessResult {
        settings.migrateLLMProviderIfNeeded()
        let profile = loadProfile(appId: appId, storePath: settings.storePath)
        let tone = profile?.tone
        let provider = settings.llmPolishProvider

        var text = applyDictionary(raw, storePath: settings.storePath)

        let skipFillers = profile?.format.skipFillerRemoval == true
        if settings.enableRulesPostprocess {
            text = applyRules(text, removeFillers: !skipFillers)
        }

        var llmApplied = false
        if provider != .off, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                switch provider {
                case .off:
                    break
                case .local:
                    text = try await LocalLLMManager.shared.process(
                        text,
                        tone: tone,
                        conservative: settings.localLLMConservative,
                        timeoutSeconds: settings.localLLMTimeoutSeconds
                    )
                    llmApplied = true
                    NSLog(
                        "TextIntelligence LocalLLM ok model=%@ tone=%@",
                        LocalLLMAssets.modelFileName,
                        tone ?? "default"
                    )
                case .deepseek:
                    guard settings.deepSeekConfigured else {
                        NSLog("TextIntelligence DeepSeek skipped: API Key 未配置")
                        break
                    }
                    text = try await DeepSeekPostProcessor.process(
                        text,
                        tone: tone,
                        config: settings.deepSeekConfig
                    )
                    llmApplied = true
                    NSLog(
                        "TextIntelligence DeepSeek ok model=%@ tone=%@",
                        settings.deepSeekModel,
                        tone ?? "default"
                    )
                }
            } catch {
                NSLog("TextIntelligence \(provider.rawValue) fallback: \(error.localizedDescription)")
            }
        }

        if let profile {
            text = applyProfileFormat(text, format: profile.format)
        }

        return ProcessResult(
            text: text,
            tone: tone,
            appId: appId,
            profileApplied: profile != nil,
            llmApplied: llmApplied,
            llmProvider: provider
        )
    }

    static func loadProfile(appId: String?, storePath: String) -> AppProfile? {
        guard let appId, !appId.isEmpty else { return nil }
        do {
            return try LocalStore(path: storePath).getAppProfile(appId: appId)
        } catch {
            NSLog("TextIntelligence profile lookup skipped: \(error.localizedDescription)")
            return nil
        }
    }

    static func applyDictionary(_ input: String, storePath: String) -> String {
        do {
            let store = try LocalStore(path: storePath)
            var text = input
            for entry in try store.listDictionary() where !entry.phrase.isEmpty {
                text = text.replacingOccurrences(of: entry.phrase, with: entry.replacement)
            }
            return text
        } catch {
            NSLog("TextIntelligence dictionary skipped: \(error.localizedDescription)")
            return input
        }
    }

    static func applyRules(_ input: String, removeFillers: Bool = true) -> String {
        var text = input
        if removeFillers {
            text = Self.removeFillers(text)
        }
        text = normalizeWhitespace(text)
        return text
    }

    static func applyProfileFormat(_ input: String, format: AppProfileFormatSettings) -> String {
        var text = input
        if format.stripTrailingPeriod {
            text = stripTrailingPeriod(text)
        }
        return text
    }

    private static func removeFillers(_ s: String) -> String {
        var out = s
        for word in fillerWords {
            out = out.replacingOccurrences(of: word, with: "")
            out = out.replacingOccurrences(of: word.uppercased(), with: "")
            out = out.replacingOccurrences(of: word.lowercased(), with: "")
        }
        return out
    }

    private static func normalizeWhitespace(_ s: String) -> String {
        s.split { $0.isWhitespace }.joined(separator: " ")
    }

    private static func stripTrailingPeriod(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("。") || text.hasSuffix(".") || text.hasSuffix("．") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
