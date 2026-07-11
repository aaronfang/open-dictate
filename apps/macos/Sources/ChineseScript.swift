import Foundation

/// Preferred Chinese character script for dictation output.
enum ChineseScriptPreference: String, CaseIterable, Identifiable {
    case simplified
    case traditional
    case asIs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplified: return "简体"
        case .traditional: return "繁体"
        case .asIs: return "不转换"
        }
    }

    /// Hint injected into the LLM polish prompt.
    var promptHint: String? {
        switch self {
        case .simplified: return "汉字一律使用简体中文，不要输出繁体字"
        case .traditional: return "汉字一律使用繁体中文，不要输出简体字"
        case .asIs: return nil
        }
    }

    func normalize(_ text: String) -> String {
        ChineseScriptNormalizer.apply(text, preference: self)
    }
}

enum ChineseScriptNormalizer {
    static func apply(_ text: String, preference: ChineseScriptPreference) -> String {
        switch preference {
        case .asIs:
            return text
        case .simplified:
            return transform(text, id: "Hant-Hans")
        case .traditional:
            return transform(text, id: "Hans-Hant")
        }
    }

    private static func transform(_ text: String, id: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, id as CFString, false)
        return mutable as String
    }
}
