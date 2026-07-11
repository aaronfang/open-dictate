import Foundation

/// Detect manual post-dictation edits and turn them into dictionary replacements.
enum CorrectionLearner {
    struct Pair: Equatable {
        let phrase: String
        let replacement: String
    }

    /// Single characters are too broad and cause false replacements.
    private static let minTokenLength = 2
    private static let maxTokenLength = 10
    private static let resyncRun = 2
    private static let maxHunks = 5
    private static let searchWindow = 64

    /// Find a near-match of `original` inside `fieldValue` that differs (user correction).
    static func findCorrectedVariant(original: String, in fieldValue: String) -> String? {
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let field = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard originalTrimmed.count >= 4, field.count >= 4 else { return nil }
        if field == originalTrimmed { return nil }
        if field.contains(originalTrimmed) { return nil }

        let oChars = Array(originalTrimmed)
        let fChars = Array(field)
        let oCount = oChars.count
        let minLen = max(4, oCount - max(6, oCount / 3))
        let maxLen = min(fChars.count, oCount + max(6, oCount / 3))
        guard minLen <= maxLen else { return nil }

        var bestScore = 0.0
        var bestText: String?

        for len in minLen...maxLen {
            let lastStart = fChars.count - len
            guard lastStart >= 0 else { continue }
            for start in 0...lastStart {
                let candidateChars = Array(fChars[start..<(start + len)])
                let lcs = longestCommonSubsequenceLength(oChars, candidateChars)
                let score = Double(lcs) / Double(max(oCount, len))
                if score >= 0.72, score < 0.999, score > bestScore {
                    bestScore = score
                    bestText = String(candidateChars)
                }
            }
        }
        return bestText
    }

    /// Extract discrete word-ish phrase→replacement pairs (not one giant middle span).
    static func extractPairs(from original: String, to corrected: String) -> [Pair] {
        let a = Array(original.trimmingCharacters(in: .whitespacesAndNewlines))
        let b = Array(corrected.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !a.isEmpty, a != b else { return [] }

        var pairs: [Pair] = []
        var seen = Set<String>()

        for hunk in diffHunks(a: a, b: b) {
            guard let pair = learnablePair(a: a, b: b, hunk: hunk) else { continue }
            guard seen.insert(pair.phrase).inserted else { continue }
            pairs.append(pair)
            if pairs.count >= maxHunks { break }
        }
        return pairs
    }

    // MARK: - Diff

    private struct Hunk {
        var aStart: Int
        var aEnd: Int
        var bStart: Int
        var bEnd: Int

        var aCount: Int { aEnd - aStart }
        var bCount: Int { bEnd - bStart }
    }

    private static func diffHunks(a: [Character], b: [Character]) -> [Hunk] {
        var hunks: [Hunk] = []
        var i = 0
        var j = 0

        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                i += 1
                j += 1
                continue
            }

            let i0 = i
            let j0 = j
            guard let sync = findResync(a: a, b: b, i: i, j: j) else {
                hunks.append(Hunk(aStart: i0, aEnd: a.count, bStart: j0, bEnd: b.count))
                break
            }
            if sync.ai > i0 || sync.bj > j0 {
                hunks.append(Hunk(aStart: i0, aEnd: sync.ai, bStart: j0, bEnd: sync.bj))
            }
            i = sync.ai
            j = sync.bj
            if hunks.count >= maxHunks { break }
        }
        return hunks
    }

    private static func findResync(a: [Character], b: [Character], i: Int, j: Int) -> (ai: Int, bj: Int)? {
        let aLimit = min(a.count, i + searchWindow)
        let bLimit = min(b.count, j + searchWindow)

        var best: (ai: Int, bj: Int, cost: Int, run: Int)?
        for ai in i...aLimit {
            for bj in j...bLimit {
                if ai == i, bj == j { continue }
                let run = matchRunLength(a: a, b: b, ai: ai, bj: bj)
                let atEnd = ai == a.count && bj == b.count
                // Allow a 1-char resync when it consumes the remainder (e.g. trailing「就」).
                let coversRest = run >= 1 && ai + run == a.count && bj + run == b.count
                guard run >= resyncRun || atEnd || coversRest else { continue }
                let cost = (ai - i) + (bj - j)
                // Prefer the nearest resync (smallest edit span) so multiple
                // word fixes stay separate. Break ties with longer runs.
                if let cur = best {
                    if cost < cur.cost
                        || (cost == cur.cost && run > cur.run)
                        || (cost == cur.cost && run == cur.run && ai + bj < cur.ai + cur.bj) {
                        best = (ai, bj, cost, run)
                    }
                } else {
                    best = (ai, bj, cost, run)
                }
            }
        }
        return best.map { ($0.ai, $0.bj) }
    }

    private static func matchRunLength(a: [Character], b: [Character], ai: Int, bj: Int) -> Int {
        var n = 0
        while ai + n < a.count, bj + n < b.count, a[ai + n] == b[bj + n] {
            n += 1
        }
        return n
    }

    // MARK: - Learnability

    private static func learnablePair(a: [Character], b: [Character], hunk: Hunk) -> Pair? {
        var aStart = hunk.aStart
        var aEnd = hunk.aEnd
        var bStart = hunk.bStart
        var bEnd = hunk.bEnd

        let coreShort = hunk.aCount < minTokenLength || hunk.bCount < minTokenLength

        if coreShort {
            // 招→造 + 海螺… => 招海螺→造海螺. Stop once both sides are multi-char.
            expandRight(
                a: a, b: b,
                aStart: aStart, aEnd: &aEnd,
                bStart: bStart, bEnd: &bEnd,
                max: 3
            )
        } else {
            // 攻爽→空船 + 左侧「防」 => 防攻爽→防空船；不要向右吞「就准备」
            expandLeft(a: a, b: b, aStart: &aStart, bStart: &bStart, max: 1)
            trimSharedStops(a: a, b: b, aStart: &aStart, aEnd: &aEnd, bStart: &bStart, bEnd: &bEnd)
        }

        let phrase = String(a[aStart..<aEnd])
        let replacement = String(b[bStart..<bEnd])
        guard isLearnable(phrase: phrase, replacement: replacement) else { return nil }
        return Pair(phrase: phrase, replacement: replacement)
    }

    private static let stopChars: Set<Character> = [
        "的", "了", "吗", "呢", "吧", "啊", "呀", "么",
        "一", "个", "是", "在", "和", "与", "或", "就", "都", "也", "很", "先"
    ]

    private static func expandLeft(
        a: [Character], b: [Character],
        aStart: inout Int, bStart: inout Int,
        max: Int
    ) {
        var n = 0
        while n < max, aStart > 0, bStart > 0,
              a[aStart - 1] == b[bStart - 1],
              isContentChar(a[aStart - 1]) {
            aStart -= 1
            bStart -= 1
            n += 1
        }
    }

    private static func expandRight(
        a: [Character], b: [Character],
        aStart: Int, aEnd: inout Int,
        bStart: Int, bEnd: inout Int,
        max: Int
    ) {
        var n = 0
        while n < max, aEnd < a.count, bEnd < b.count,
              a[aEnd] == b[bEnd],
              isContentChar(a[aEnd]) {
            aEnd += 1
            bEnd += 1
            n += 1
            // Enough to form a reusable multi-char phrase — don't glue on「要/打」etc.
            if (aEnd - aStart) >= minTokenLength, (bEnd - bStart) >= minTokenLength {
                // Prefer a 2–3 char compound when available (招+海螺), but never past max.
                if n >= 2 || (aEnd - aStart) >= 3 { break }
            }
        }
    }

    /// Drop shared leading/trailing particles that slipped into the hunk.
    private static func trimSharedStops(
        a: [Character], b: [Character],
        aStart: inout Int, aEnd: inout Int,
        bStart: inout Int, bEnd: inout Int
    ) {
        while aEnd > aStart, bEnd > bStart,
              a[aEnd - 1] == b[bEnd - 1],
              stopChars.contains(a[aEnd - 1]) || a[aEnd - 1].isPunctuation {
            aEnd -= 1
            bEnd -= 1
        }
        while aEnd > aStart, bEnd > bStart,
              a[aStart] == b[bStart],
              stopChars.contains(a[aStart]) || a[aStart].isPunctuation {
            aStart += 1
            bStart += 1
        }
    }

    private static func isContentChar(_ ch: Character) -> Bool {
        if ch.isWhitespace || ch.isNewline || ch.isPunctuation { return false }
        return !stopChars.contains(ch)
    }

    private static func isLearnable(phrase: String, replacement: String) -> Bool {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p != r else { return false }
        guard p.count >= minTokenLength, r.count >= minTokenLength else { return false }
        guard p.count <= maxTokenLength, r.count <= maxTokenLength else { return false }

        let pCore = String(p.filter { !$0.isWhitespace && !$0.isPunctuation })
        let rCore = String(r.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard pCore.count >= minTokenLength, rCore.count >= minTokenLength else { return false }
        return true
    }

    private static func longestCommonSubsequenceLength(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
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
            for k in 0..<cur.count { cur[k] = 0 }
        }
        return prev[b.count]
    }
}
