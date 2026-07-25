import Foundation

public protocol SessionRepository: Sendable {
    func record(_ session: ReadingSession) async throws
    func fetchSessions(from start: Date, to end: Date) async throws -> [ReadingSession]
}
