import Foundation

/// Batch job kind for whole-document AI processing.
public enum DocumentBatchKind: String, Sendable, Equatable {
    case explain
    case translate
}

/// Aggregate learning progress for a document’s segments (iOS `ContentStore.progress`).
public struct DocumentLearningProgress: Sendable, Equatable {
    public var explained: Int
    public var translated: Int
    public var total: Int

    public init(explained: Int, translated: Int, total: Int) {
        self.explained = explained
        self.translated = translated
        self.total = total
    }

    public static func of(_ segments: [TextSegment]) -> DocumentLearningProgress {
        DocumentLearningProgress(
            explained: segments.count(where: { $0.explanation != nil }),
            translated: segments.count(where: {
                $0.translation != nil || $0.explanation != nil
            }),
            total: segments.count
        )
    }

    /// Segment IDs still needing work for a batch kind (mirrors iOS pending filter).
    public static func pendingIDs(
        in segments: [TextSegment],
        kind: DocumentBatchKind
    ) -> [UUID] {
        segments.filter { segment in
            switch kind {
            case .explain:
                return segment.explanation == nil
            case .translate:
                return segment.explanation == nil && segment.translation == nil
            }
        }
        .map(\.id)
    }
}
