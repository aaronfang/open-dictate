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
        """
        你是听写文本整理助手。只输出整理后的最终文本，不要解释、不要加引号、不要加前后缀。
        用语义理解说话人意图：默认保序保量；遇到改口、拼写纠正、句子重说时，只保留最终想表达的内容。
        """

    static func user(
        text: String,
        tone: String?,
        conservative: Bool,
        previousText: String? = nil,
        script: ChineseScriptPreference = .simplified
    ) -> String {
        let toneHint = (tone?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "中性书面，清晰自然"
        let conservativeHint = conservative
            ? "极少同义改写与调序；但语义改口、专有名词拼写纠正、句子重说产生的废稿必须删掉"
            : "可轻度润色，保持原意；改口与拼写纠正后只留最终说法，不新增事实"
        let scriptHint = script.promptHint.map { "；\($0)" } ?? ""

        var previousBlock = ""
        if let previousText, !previousText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previousBlock = """

            上一笔已上屏文本（仅当本次整段是在编辑上一笔时才改它，否则完全忽略）：
            \(previousText)
            """
        }

        return """
        请整理下面的口语转写。

        硬性规则：
        1. 【语义改口】根据上下文判断说话人最终想表达什么。
           - 纠正前文：只保留最终意图，删掉被否定/被替代的旧说法。
           - 专有名词/英文拼写：若先说错或含糊，再强调正确拼写（如「拼法是 TYPELESS」），只保留正确写法，删掉错误拼写尝试。
           - 句子重说：纠正后若重新起头把前半句再说一遍，只保留重说后的完整句，不要把两遍都留下。
           - 停顿/补充/转折（如「等一下」「然后」「那么」）不是改口，保留全文。
           - 靠语义判断，不要靠固定关键词一刀切。
           正例：「明天去北京，哦不对，去上海」→「明天去上海」
           正例：「相对于 tlesstyless 的拼法是 TYPELESS，相对于 tless 当前仍然缺失的…」
                →「相对于 TYPELESS，当前仍然缺失的…」（删掉错误拼写与重复起头）
           正例：「家里没有矿，等一下这个牛车就在家里挖土，怎么行呢？」→ 保留前后文，只整理通顺
           反例：把长段口述摘要成最后一句；或把错误拼写与正确拼写一并保留
        2. 【保序】无纠正时，保持原句信息顺序与主要用词；禁止把后半句挪到前面。
        3. 【保量】禁止摘要成一句；最终意图中的信息点应齐全。被改口废掉的片段不算「必须保留」。
        4. 【删改上一笔】仅当本次整段是编辑指令（如「把第三条删掉」）时，才改「上一笔已上屏文本」。
        5. 可删口头禅与无意义重复；可补标点；问句用问号。不要同义改写整句，不新增事实。
        6. 风格：\(toneHint)；\(conservativeHint)\(scriptHint)。
        \(previousBlock)
        本次转写：
        \(text)
        """
    }

    static let askSystem =
        """
        你是文本编辑助手。根据用户的语音指令改写或处理给定选区文本。
        只输出最终结果文本，不要解释、不要加引号、不要加前后缀。
        若指令是提问且需要回答，直接给出简洁答案。
        """

    static func askUser(selected: String, instruction: String) -> String {
        """
        选区文本：
        \(selected)

        用户指令：
        \(instruction)

        请按指令处理选区并只输出结果。
        """
    }
}
