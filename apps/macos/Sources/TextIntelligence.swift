import Foundation

enum TextIntelligence {
    /// Filler list tightened vs Core: omit 就是 / 然后 (too easy to false-positive).
    private static let fillerWords: [String] = [
        "um", "uh", "you know", "like",
        "额", "嗯", "呃", "你知道",
    ]

    /// Dictionary replace → optional rule post-process. Mirrors Core pipeline order.
    static func process(_ raw: String, settings: AppSettings) -> String {
        var text = applyDictionary(raw, storePath: settings.storePath)
        if settings.enableRulesPostprocess {
            text = applyRules(text)
        }
        return text
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

    static func applyRules(_ input: String) -> String {
        var text = removeFillers(input)
        text = normalizeWhitespace(text)
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
}
