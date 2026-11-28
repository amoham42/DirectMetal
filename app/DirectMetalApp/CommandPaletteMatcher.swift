import Foundation

// Pure Foundation fuzzy/word-boundary/CamelCase/diacritic matcher for CommandPaletteSheet.
// SwiftUI Command Palette sheet lives in CommandPaletteSheet.swift.
// Quick-Launch Command Palette (⌘K): Spotlight-style fuzzy search across the game library
// and launcher quick actions, with full keyboard navigation and instant game launch (⌘↩).

// MARK: - Fuzzy / substring matcher (pure, unit-testable)

/// Pure fuzzy and substring ranker used by `CommandPaletteSheet`.
///
/// Score tiers (for non-empty queries, higher is better):
/// - Exact match: `1000`
/// - Prefix match: `800...900`
/// - Word-boundary substring match: `600...750`
/// - Mid-word substring match: `400...550`
/// - Subsequence (fuzzy) match: `1...350`
/// - Empty query: `0`
/// - Non-match: `nil`
enum CommandPaletteMatcher {
    static func score(query: String, text: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard !text.isEmpty else { return nil }

        let collapsedQuery = trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        let normQuery = normalize(collapsedQuery)
        let normText = normalize(text)
        guard !normQuery.isEmpty, !normText.isEmpty else { return nil }

        if normText == normQuery {
            return 1000
        }

        let qChars = Array(normQuery)
        let tChars = Array(normText)
        let origChars = Array(text)
        let useOriginalForCamelCase = origChars.count == tChars.count

        // Prefix match (800...900): shorter targets rank higher.
        if qChars.count <= tChars.count && normText.hasPrefix(normQuery) {
            let lengthBonus = max(0, 100 - (tChars.count - qChars.count))
            return 800 + lengthBonus
        }

        // Contiguous substring scan: prefer the earliest word-boundary occurrence over mid-word.
        if qChars.count <= tChars.count {
            var earliestBoundary: Int?
            var earliestAny: Int?
            let maxStart = tChars.count - qChars.count
            for start in 0...maxStart {
                if matchesContiguous(qChars, in: tChars, at: start) {
                    if earliestAny == nil {
                        earliestAny = start
                    }
                    if earliestBoundary == nil && isWordBoundary(at: start, normChars: tChars, origChars: origChars, useOriginal: useOriginalForCamelCase) {
                        earliestBoundary = start
                        break
                    }
                }
            }

            if let idx = earliestBoundary {
                let positionBonus = max(0, 100 - idx)
                let lengthBonus = max(0, 50 - (tChars.count - qChars.count) / 2)
                return 600 + positionBonus + lengthBonus
            }

            if let idx = earliestAny {
                let positionBonus = max(0, 100 - idx)
                let lengthBonus = max(0, 50 - (tChars.count - qChars.count) / 2)
                return 400 + positionBonus + lengthBonus
            }
        }

        // Subsequence match (1...350), first against the query as-is, then ignoring spaces
        // so multi-word queries like "direct metal" match CamelCase targets like "DirectMetal".
        if let sub = subsequenceScore(qChars: qChars, tChars: tChars, origChars: origChars, useOriginal: useOriginalForCamelCase) {
            return sub
        }

        let compactQuery = qChars.filter { !$0.isWhitespace }
        if compactQuery.count < qChars.count, !compactQuery.isEmpty {
            return subsequenceScore(qChars: compactQuery, tChars: tChars, origChars: origChars, useOriginal: useOriginalForCamelCase)
        }

        return nil
    }

    /// Scores a primary title alongside secondary searchable keywords (badges, storefront, exe name).
    /// Keyword-only matches are discounted so title matches always rank above metadata matches.
    static func score(query: String, title: String, keywords: [String]) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var best = score(query: trimmed, text: title)
        for keyword in keywords where !keyword.isEmpty {
            if let kwScore = score(query: trimmed, text: keyword) {
                let discounted = max(1, (kwScore * 6) / 10)
                if best == nil || discounted > best! {
                    best = discounted
                }
            }
        }
        return best
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func matchesContiguous(_ q: [Character], in t: [Character], at start: Int) -> Bool {
        for i in 0..<q.count {
            if t[start + i] != q[i] { return false }
        }
        return true
    }

    private static func isWordBoundary(at index: Int, normChars: [Character], origChars: [Character], useOriginal: Bool) -> Bool {
        if index == 0 { return true }
        let prev = normChars[index - 1]
        let curr = normChars[index]
        if !(prev.isLetter || prev.isNumber) && (curr.isLetter || curr.isNumber) {
            return true
        }
        if useOriginal && origChars[index - 1].isLowercase && origChars[index].isUppercase {
            return true
        }
        return false
    }

    private static func subsequenceScore(qChars: [Character], tChars: [Character], origChars: [Character], useOriginal: Bool) -> Int? {
        guard !qChars.isEmpty, qChars.count <= tChars.count else { return nil }

        // Backward pass computes the latest valid match index for each query character so
        // the forward pass can safely prefer consecutive and word-boundary positions.
        var lastPos = Array(repeating: -1, count: qChars.count)
        var tIdx = tChars.count - 1
        for qIdx in stride(from: qChars.count - 1, through: 0, by: -1) {
            let needed = qChars[qIdx]
            while tIdx >= 0 && tChars[tIdx] != needed {
                tIdx -= 1
            }
            guard tIdx >= 0 else { return nil }
            lastPos[qIdx] = tIdx
            tIdx -= 1
        }

        var matched: [Int] = []
        matched.reserveCapacity(qChars.count)
        var prev = -1

        for qIdx in 0..<qChars.count {
            let needed = qChars[qIdx]
            let lower = prev + 1
            let upper = lastPos[qIdx]
            guard lower <= upper else { return nil }

            var chosen: Int?
            // 1. Consecutive character continuation
            if qIdx > 0 && tChars[lower] == needed {
                chosen = lower
            }
            // 2. Word-boundary character match
            if chosen == nil {
                for j in lower...upper where tChars[j] == needed {
                    if isWordBoundary(at: j, normChars: tChars, origChars: origChars, useOriginal: useOriginal) {
                        chosen = j
                        break
                    }
                }
            }
            // 3. Earliest available match
            if chosen == nil {
                for j in lower...upper where tChars[j] == needed {
                    chosen = j
                    break
                }
            }

            guard let picked = chosen else { return nil }
            matched.append(picked)
            prev = picked
        }

        var boundaryHits = 0
        var consecutiveHits = 0
        for (i, pos) in matched.enumerated() {
            if isWordBoundary(at: pos, normChars: tChars, origChars: origChars, useOriginal: useOriginal) {
                boundaryHits += 1
            }
            if i > 0 && pos == matched[i - 1] + 1 {
                consecutiveHits += 1
            }
        }

        let first = matched.first ?? 0
        let last = matched.last ?? first
        let span = last - first + 1
        let gapPenalty = max(0, span - matched.count)

        let raw = 120 + boundaryHits * 24 + consecutiveHits * 16 - gapPenalty * 3 - first * 2
        return min(350, max(1, raw))
    }
}

