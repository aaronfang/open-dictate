import Foundation

enum TextIntelligence {
    /// Filler list tightened vs Core: omit 就是 / 然后 (too easy to false-positive).
    private static let fillerWords: [String] = [
        "um", "uh", "you know", "like",
        "额", "嗯", "呃", "你知道",
    ]

    /// Hard self-correction cues — may truncate text before the cue.
    /// Intentionally excludes discourse pauses like「等一下/等会儿/稍等」(those are not 改口).
    private static let hardCorrectionCues: [String] = [
        "哦不对", "啊不对", "呃不对", "欸不对", "诶不对",
        "不对，", "不对,", "不对 ", "不对。",
        "不是，", "不是,", "不是 ",
        "我说错了", "说错了", "讲错了",
        "我是说", "我想说", "想说的是", "应该说",
        "更正一下", "改正一下", "重说", "重新说",
        "改成", "改成：", "应该是",
        // Common STT garble of「哦不对」
        "二部队", "二部隊", "哦部队", "哦部隊",
        // English
        "actually ", "i mean ", "scratch that", "no wait",
    ]

    /// Looks like an edit instruction against previously delivered text.
    private static let revisionPatterns: [NSRegularExpression] = {
        let patterns = [
            #"把第.+[条点项段句].{0,8}(去掉|删掉|删除|移除)"#,
            #"(删掉|去掉|删除|移除)第.+[条点项段句]"#,
            #"(删掉|去掉|删除)最后.+"#,
            #"第.+[条点项].{0,6}改成"#,
            #"把最后.+(改成|换成)"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

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
        appId: String? = nil,
        previousText: String? = nil
    ) async -> ProcessResult {
        settings.migrateLLMProviderIfNeeded()
        let profile = loadProfile(appId: appId, storePath: settings.storePath)
        let tone = profile?.tone
        let provider = settings.llmPolishProvider

        // Empty / nospeech-like input must not reach the LLM with "previous text",
        // or the model often echoes the last paste (clipboard) back for insertion.
        if isEffectivelyEmptyTranscript(raw) {
            NSLog("TextIntelligence: skip empty/weak transcript")
            return ProcessResult(
                text: "",
                tone: tone,
                appId: appId,
                profileApplied: false,
                llmApplied: false,
                llmProvider: provider
            )
        }

        var text = applyDictionary(raw, storePath: settings.storePath)
        text = settings.chineseScript.normalize(text)

        let skipFillers = profile?.format.skipFillerRemoval == true
        // Keyword 改口 truncation is a fallback only when LLM is off — with LLM we
        // rely on semantic understanding + divergence guards instead.
        if settings.enableRulesPostprocess {
            text = applyRules(
                text,
                removeFillers: !skipFillers,
                applyKeywordCorrection: provider == .off
            )
            text = settings.chineseScript.normalize(text)
        }

        if isEffectivelyEmptyTranscript(text) {
            NSLog("TextIntelligence: empty after rules — skip LLM/paste")
            return ProcessResult(
                text: "",
                tone: tone,
                appId: appId,
                profileApplied: false,
                llmApplied: false,
                llmProvider: provider
            )
        }

        let looksLikeRevision = isRevisionCommand(text)
        let previous = previousText?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only send previous text when this turn looks like an edit command.
        // Always sending it caused empty/weak turns to be "filled in" from clipboard history.
        let previousForLLM: String? = looksLikeRevision
            ? previous.map { settings.chineseScript.normalize($0) }
            : nil

        var llmApplied = false
        let preLLM = text
        if provider != .off, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let polished: String?
                switch provider {
                case .off:
                    polished = nil
                case .local:
                    polished = try await LocalLLMManager.shared.process(
                        text,
                        tone: tone,
                        conservative: settings.localLLMConservative,
                        timeoutSeconds: settings.localLLMTimeoutSeconds,
                        previousText: previousForLLM,
                        script: settings.chineseScript
                    )
                case .deepseek:
                    if settings.deepSeekConfigured {
                        polished = try await DeepSeekPostProcessor.process(
                            text,
                            tone: tone,
                            config: settings.deepSeekConfig,
                            previousText: previousForLLM,
                            script: settings.chineseScript
                        )
                    } else {
                        NSLog("TextIntelligence DeepSeek skipped: API Key 未配置")
                        polished = nil
                    }
                }

                if let polished {
                    let normalizedPolished = settings.chineseScript.normalize(polished)
                    // Keyword cues no longer unlock "rewrite freely". Only explicit
                    // edit-previous commands relax checks; mid-utterance 改口 is judged
                    // by subsequence / retention heuristics.
                    if isPolishTooDivergent(
                        original: preLLM,
                        polished: normalizedPolished,
                        allowRewrite: looksLikeRevision
                    ) {
                        NSLog(
                            "TextIntelligence LLM rejected (too divergent): in=%@ out=%@",
                            preLLM,
                            normalizedPolished
                        )
                    } else if let previous,
                              !looksLikeRevision,
                              contentCharacters(normalizedPolished) == contentCharacters(previous),
                              contentCharacterCount(preLLM) < 4 {
                        // Weak input + LLM echoed last delivery — do not paste again.
                        NSLog(
                            "TextIntelligence LLM rejected (echoed previous on weak input): in=%@ out=%@",
                            preLLM,
                            normalizedPolished
                        )
                    } else {
                        text = normalizedPolished
                        llmApplied = true
                        NSLog(
                            "TextIntelligence \(provider.rawValue) ok in=%@ out=%@",
                            preLLM,
                            normalizedPolished
                        )
                    }
                }
            } catch {
                NSLog("TextIntelligence \(provider.rawValue) fallback: \(error.localizedDescription)")
            }
        } else if looksLikeRevision, let previous, !previous.isEmpty {
            NSLog("TextIntelligence revision without LLM — keeping previous text")
            text = settings.chineseScript.normalize(previous)
        }

        if let profile {
            text = applyProfileFormat(text, format: profile.format)
        }
        text = settings.chineseScript.normalize(text)

        return ProcessResult(
            text: text,
            tone: tone,
            appId: appId,
            profileApplied: profile != nil,
            llmApplied: llmApplied,
            llmProvider: provider
        )
    }

    /// Ask AI: apply a spoken instruction to selected text via the configured LLM.
    static func ask(
        selected: String,
        instruction: String,
        settings: AppSettings
    ) async throws -> String {
        settings.migrateLLMProviderIfNeeded()
        let selectedTrimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionTrimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedTrimmed.isEmpty else {
            throw AskError.emptySelection
        }
        guard !instructionTrimmed.isEmpty else {
            throw AskError.emptyInstruction
        }

        let provider = settings.llmPolishProvider
        let result: String
        switch provider {
        case .off:
            throw AskError.llmRequired
        case .local:
            result = try await LocalLLMManager.shared.ask(
                selected: selectedTrimmed,
                instruction: instructionTrimmed,
                timeoutSeconds: settings.localLLMTimeoutSeconds
            )
        case .deepseek:
            guard settings.deepSeekConfigured else { throw AskError.llmRequired }
            result = try await DeepSeekPostProcessor.ask(
                selected: selectedTrimmed,
                instruction: instructionTrimmed,
                config: settings.deepSeekConfig
            )
        }
        return settings.chineseScript.normalize(result)
    }

    enum AskError: LocalizedError {
        case emptySelection
        case emptyInstruction
        case llmRequired

        var errorDescription: String? {
            switch self {
            case .emptySelection: return "未选中文本"
            case .emptyInstruction: return "未识别到指令"
            case .llmRequired: return "Ask AI 需要开启本地或 DeepSeek 润色"
            }
        }
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

    static func applyRules(
        _ input: String,
        removeFillers: Bool = true,
        applyKeywordCorrection: Bool = false
    ) -> String {
        var text = input
        text = normalizeCorrectionGarbles(text)
        // Keyword truncation is opt-in (LLM-off fallback only). Prefer semantic 改口 via LLM.
        if applyKeywordCorrection {
            text = applySelfCorrectionHeuristics(text)
        }
        if removeFillers {
            text = Self.removeFillers(text)
        }
        text = collapseRepeatedTokens(text)
        text = normalizeWhitespace(text)
        text = ensureBasicChinesePunctuation(text)
        return text
    }

    /// When STT returns woitn (no commas/periods), insert light clause punctuation.
    static func ensureBasicChinesePunctuation(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        let hasPunct = text.contains { "，。？！、；：".contains($0) }
        if !hasPunct {
            let markers = ["帮我", "麻烦", "然后", "所以", "但是", "不过", "另外", "还有", "请问", "接下来"]
            for marker in markers {
                guard let range = text.range(of: marker), range.lowerBound > text.startIndex else { continue }
                let prev = text[text.index(before: range.lowerBound)]
                if isCJKOrLetter(prev) {
                    text.insert(contentsOf: "，", at: range.lowerBound)
                    break
                }
            }
        }

        let trimmedEnd = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEnd.isEmpty {
            let last = trimmedEnd.last!
            if !"，。？！、；：,.!?".contains(last) {
                let questionHints = ["吗", "呢", "哪些", "什么", "怎么", "为什么", "几", "多少", "能否", "可以吗"]
                if questionHints.contains(where: { trimmedEnd.contains($0) }) {
                    text += "？"
                } else {
                    text += "。"
                }
            }
        }
        return text
    }

    private static func isCJKOrLetter(_ ch: Character) -> Bool {
        if ch.isLetter { return true }
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)
    }

    static func applyProfileFormat(_ input: String, format: AppProfileFormatSettings) -> String {
        var text = input
        if format.stripTrailingPeriod {
            text = stripTrailingPeriod(text)
        }
        return text
    }

    /// True when recognition is empty, nospeech, or only fillers/punctuation — must not paste.
    static func isEffectivelyEmptyTranscript(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return true }
        let lowered = s.lowercased()
        if lowered.contains("<|nospeech|>") || lowered.contains("[nospeech]") {
            return true
        }
        // Strip common SenseVoice / whisper tags.
        for tag in ["<|nospeech|>", "<|zh|>", "<|en|>", "<|yue|>", "<|ja|>", "<|ko|>",
                    "<|NEUTRAL|>", "<|HAPPY|>", "<|SAD|>", "<|ANGRY|>",
                    "<|withitn|>", "<|woitn|>"] {
            s = s.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        let content = contentCharacterCount(s)
        if content == 0 { return true }
        // Lone fillers / acknowledgements with no substance.
        let fillers: Set<String> = ["嗯", "啊", "呃", "额", "哦", "噢", "唔", "嘿", "嗨", "um", "uh", "ah", "oh"]
        if content <= 2, fillers.contains(s.lowercased()) { return true }
        return false
    }

    /// Ask model returned the spoken instruction instead of editing the selection.
    static func isAskResultInstructionLeak(
        selected: String,
        instruction: String,
        result: String
    ) -> Bool {
        let sel = contentCharacters(selected)
        let ins = contentCharacters(instruction)
        let out = contentCharacters(result)
        guard ins.count >= 4, out.count >= 4 else { return false }

        let lcsInstr = longestCommonSubsequenceLength(ins, out)
        let fromInstruction = Double(lcsInstr) / Double(out.count)

        // Output is essentially the spoken line.
        if fromInstruction >= 0.88 {
            // Allow only if selection was already almost the same as instruction
            // (rare) — otherwise this is dictation-via-Ask.
            if sel.count >= 4 {
                let lcsSel = longestCommonSubsequenceLength(sel, out)
                let fromSelection = Double(lcsSel) / Double(out.count)
                if fromSelection >= 0.75 { return false }
            }
            return true
        }
        return false
    }

    private static func contentCharacterCount(_ text: String) -> Int {
        contentCharacters(text).count
    }

    /// Reject LLM output that invents wording, reorders freely, or drops most content.
    /// Mid-utterance 改口 / spelling fixes are allowed when the result is mostly from the input.
    static func isPolishTooDivergent(original: String, polished: String, allowRewrite: Bool) -> Bool {
        if looksLikeSpacedCJK(polished) {
            return true
        }
        let o = contentCharacters(original)
        let p = contentCharacters(polished)
        guard o.count >= 4 else { return false }

        let lcs = longestCommonSubsequenceLength(o, p)
        let retention = Double(p.count) / Double(o.count)
        let fromOriginal = p.isEmpty ? 1.0 : Double(lcs) / Double(p.count)

        let oCJK = o.filter(isCJKScalar)
        let pCJK = p.filter(isCJKScalar)
        let cjkRetention: Double = oCJK.isEmpty
            ? 1.0
            : Double(pCJK.count) / Double(oCJK.count)

        // Must mostly reuse original characters (blocks free paraphrase / hallucination).
        if fromOriginal < 0.78 {
            return true
        }

        // Catastrophic shortening — but allow dropping Latin spelling attempts /
        // repeated false starts when CJK substance is largely kept.
        if o.count >= 20, retention < 0.45 {
            let spellingCleanup = oCJK.count >= 8 && cjkRetention >= 0.72 && fromOriginal >= 0.85
            if !spellingCleanup {
                return true
            }
        }

        if allowRewrite {
            return false
        }

        let orderRatio = Double(lcs) / Double(o.count)
        // Semantic 改口 / 拼写纠正 may drop a wrong span or restart the sentence.
        if orderRatio < 0.82 {
            if fromOriginal >= 0.88, (retention >= 0.45 || cjkRetention >= 0.72) {
                return false
            }
            return true
        }

        // Lead check only when almost everything was kept (prefix shouldn't vanish).
        if o.count >= 6, retention >= 0.85, cjkRetention >= 0.9 {
            let leadLen = min(4, o.count)
            let lead = String(o.prefix(leadLen))
            if !String(p).contains(lead) {
                return true
            }
        }

        return false
    }

    private static func isCJKScalar(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)
    }

    /// "后 面 还 有 哪 些" — model inserted spaces between CJK chars.
    static func looksLikeSpacedCJK(_ s: String) -> Bool {
        let parts = s.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 3 else { return false }
        let singleHan = parts.filter { part in
            part.count == 1 && part.unicodeScalars.allSatisfy { scalar in
                let v = scalar.value
                return (0x4E00...0x9FFF).contains(v)
            }
        }
        return Double(singleHan.count) / Double(parts.count) >= 0.7
    }

    private static func contentCharacters(_ s: String) -> [Character] {
        s.filter { ch in
            !ch.isWhitespace && !ch.isPunctuation && !ch.isNewline
        }
    }

    private static func longestCommonSubsequenceLength(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        // Memory-efficient LCS DP (two rows).
        var prev = Array(repeating: 0, count: b.count + 1)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    cur[j] = prev[j - 1] + 1
                } else {
                    cur[j] = max(prev[j], cur[j - 1])
                }
            }
            swap(&prev, &cur)
            cur = Array(repeating: 0, count: b.count + 1)
        }
        return prev[b.count]
    }

    static func isRevisionCommand(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= 80 else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return revisionPatterns.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    /// Map common STT mishearings of correction phrases back to canonical cues.
    static func normalizeCorrectionGarbles(_ input: String) -> String {
        var text = input
        let replacements = [
            "二部隊": "哦不对",
            "二部队": "哦不对",
            "哦部隊": "哦不对",
            "哦部队": "哦不对",
            "额不对": "哦不对",
            "喔不对": "哦不对",
        ]
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    /// Keyword fallback when LLM is off: keep text after the rightmost hard cue.
    /// Prefer semantic 改口 via LLM when available — do not call this on the LLM path.
    static func applySelfCorrectionHeuristics(_ input: String) -> String {
        let lower = input.lowercased()
        var rightmostLowerBound: String.Index?
        var rightmostUpperBound: String.Index?
        for cue in hardCorrectionCues {
            let needle = cue.lowercased()
            if let range = lower.range(of: needle, options: .backwards) {
                if rightmostLowerBound == nil || range.lowerBound > rightmostLowerBound! {
                    rightmostLowerBound = range.lowerBound
                    rightmostUpperBound = range.upperBound
                }
            }
        }
        guard let lowerBound = rightmostLowerBound, let upperBound = rightmostUpperBound else {
            return input
        }
        // Avoid truncating long dictations on a mid-sentence cue unless the tail is substantial
        // and the dropped head isn't the bulk of the utterance.
        let before = String(input[input.startIndex..<input.index(input.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: lowerBound))])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var after = String(input[input.index(input.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: upperBound))...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading punctuation left by the cue.
        while after.hasPrefix("，") || after.hasPrefix(",") || after.hasPrefix("。") || after.hasPrefix("、") {
            after = String(after.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard after.count >= 2, before.count >= 1 else { return input }
        let beforeCore = before.filter { !$0.isWhitespace && !$0.isPunctuation }.count
        let afterCore = after.filter { !$0.isWhitespace && !$0.isPunctuation }.count
        // If cue sits late and would discard most of a long utterance, keep full text
        // (likely false-positive「不是/我是说」in normal speech).
        if beforeCore + afterCore >= 24, Double(afterCore) / Double(beforeCore + afterCore) < 0.4 {
            NSLog("TextIntelligence self-correct skipped (would drop too much)")
            return input
        }
        NSLog("TextIntelligence self-correct: keep after cue → %@", after)
        return after
    }

    /// Collapse consecutive duplicate words (中文单字/词与英文 token).
    static func collapseRepeatedTokens(_ input: String) -> String {
        var text = input
        if let regex = try? NSRegularExpression(pattern: #"\b(\w+)(?:\s+\1\b)+"#, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: #"([\u4e00-\u9fff]{1,4})\1+"#, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
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
