import Foundation

enum LLMPolishProvider: String, CaseIterable, Identifiable {
    case off
    case local
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .local: return "本地模型"
        case .deepseek: return "DeepSeek 云端"
        }
    }

    /// Map legacy stored values (`ollama`) onto current cases.
    static func resolve(stored raw: String) -> LLMPolishProvider {
        if raw == "ollama" { return .local }
        return LLMPolishProvider(rawValue: raw) ?? .off
    }
}

enum LLMPolishPrompt {
    static let system =
        "你是听写文本整理助手。只输出整理后的最终文本，不要解释、不要加引号、不要加前后缀。"

    static func user(text: String, tone: String?, conservative: Bool) -> String {
        let toneHint = (tone?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "中性书面，清晰自然"
        let conservativeHint = conservative ? "尽量少改动，只做必要清理" : "可以适度润色，使表达更顺畅"
        return """
        请把下面的口语转写整理成更自然、清晰的文字。
        要求：删除口头禅与无意义重复，保留原意不新增事实，补全基础标点；风格参考：\(toneHint)；\(conservativeHint)。

        文本：
        \(text)
        """
    }
}
