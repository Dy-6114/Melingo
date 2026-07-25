import Foundation
import Domain

public actor MockSessionRepository: SessionRepository {
    public var sessions: [ReadingSession] = []

    public init() {}

    public func record(_ session: ReadingSession) async throws {
        sessions.append(session)
    }

    public func fetchSessions(from start: Date, to end: Date) async throws -> [ReadingSession] {
        sessions.filter { $0.startedAt >= start && $0.startedAt <= end }
    }
}
