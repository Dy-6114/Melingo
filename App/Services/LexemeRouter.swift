import Foundation

/// Routes short lexemes to Apple Translation; longer text may use the language model.
enum LexemeRouter {
    /// True when `text` is a single token (one word / CJK lemma), not a phrase or sentence.
    static func isSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.split { $0.isWhitespace || $0.isNewline }
        guard parts.count == 1 else { return false }
        let token = String(parts[0])
        // Reject obvious sentences that somehow lack spaces (rare Latin edge cases).
        if token.count > 48 { return false }
        return true
    }
}
