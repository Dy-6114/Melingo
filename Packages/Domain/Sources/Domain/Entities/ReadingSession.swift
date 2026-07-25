import Foundation

/// Append-only reading session for time-on-task statistics.
public struct ReadingSession: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var documentID: Document.ID?
    /// Local calendar date "YYYY-MM-DD".
    public var dateLocal: String
    public var startedAt: Date
    public var seconds: Int

    public init(
        id: UUID = UUID(),
        documentID: Document.ID?,
        dateLocal: String,
        startedAt: Date,
        seconds: Int
    ) {
        self.id = id
        self.documentID = documentID
        self.dateLocal = dateLocal
        self.startedAt = startedAt
        self.seconds = seconds
    }
}
