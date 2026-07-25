import Foundation

/// Study language pair: content language → explanation language.
public struct LanguagePair: Codable, Sendable, Hashable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}
