import Foundation
import NaturalLanguage

/// A tokenized span inside a sentence — only lexical words are clickable chips.
struct WordToken: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let range: Range<String.Index>
    let isWord: Bool
    /// Position among tokens in the segment (for multi-select ordering).
    let index: Int

    init(text: String, range: Range<String.Index>, isWord: Bool, segmentID: UUID, index: Int) {
        self.id = "\(segmentID.uuidString)-\(index)"
        self.text = text
        self.range = range
        self.isWord = isWord
        self.index = index
    }
}

enum WordTokenizer {
    /// Split `text` into words + intervening punctuation/whitespace.
    /// Lexical tokens (`isWord == true`) become clickable chips.
    static func tokens(in text: String, languageHint: String?, segmentID: UUID) -> [WordToken] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let languageHint {
            tokenizer.setLanguage(NLLanguage(rawValue: normalize(languageHint)))
        }

        var wordRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if isLexical(token) {
                wordRanges.append(range)
            }
            return true
        }

        var result: [WordToken] = []
        var cursor = text.startIndex
        var index = 0
        for range in wordRanges {
            if cursor < range.lowerBound {
                let gap = String(text[cursor..<range.lowerBound])
                if !gap.isEmpty {
                    result.append(WordToken(
                        text: gap, range: cursor..<range.lowerBound,
                        isWord: false, segmentID: segmentID, index: index
                    ))
                    index += 1
                }
            }
            result.append(WordToken(
                text: String(text[range]), range: range,
                isWord: true, segmentID: segmentID, index: index
            ))
            index += 1
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            let gap = String(text[cursor..<text.endIndex])
            if !gap.isEmpty {
                result.append(WordToken(
                    text: gap, range: cursor..<text.endIndex,
                    isWord: false, segmentID: segmentID, index: index
                ))
            }
        }
        return expandNewlines(result, segmentID: segmentID)
    }

    /// Split gap tokens on `\n` so layout can break lines (WordChipProseView is single-line otherwise).
    private static func expandNewlines(_ tokens: [WordToken], segmentID: UUID) -> [WordToken] {
        var out: [WordToken] = []
        out.reserveCapacity(tokens.count)
        var index = 0
        for token in tokens {
            if token.isWord || !token.text.contains(where: \.isNewline) {
                out.append(WordToken(
                    text: token.text,
                    range: token.range,
                    isWord: token.isWord,
                    segmentID: segmentID,
                    index: index
                ))
                index += 1
                continue
            }
            let parts = token.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (partIndex, part) in parts.enumerated() {
                if partIndex > 0 {
                    out.append(WordToken(
                        text: "\n",
                        range: token.range,
                        isWord: false,
                        segmentID: segmentID,
                        index: index
                    ))
                    index += 1
                }
                if !part.isEmpty {
                    out.append(WordToken(
                        text: String(part),
                        range: token.range,
                        isWord: false,
                        segmentID: segmentID,
                        index: index
                    ))
                    index += 1
                }
            }
        }
        return out
    }

    private static func isLexical(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Reject pure punctuation / symbols / digits-only noise.
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0)
            || CharacterSet.symbols.contains($0)
            || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }
        // Keep letter-containing tokens (incl. French elisions like d'août, l'été).
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func normalize(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        switch base.lowercased() {
        case "jp": return "ja"
        case "cn", "zh-cn", "cmn": return "zh-Hans"
        case "tw", "zh-tw": return "zh-Hant"
        default: return base.lowercased()
        }
    }
}
