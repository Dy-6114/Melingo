import Foundation
import SwiftData
import Domain

@ModelActor
public actor SessionSwiftDataRepository: SessionRepository {
    public func record(_ session: ReadingSession) async throws {
        modelContext.insert(ReadingSessionMapper.makeModel(from: session))
        try modelContext.save()
    }

    public func fetchSessions(from start: Date, to end: Date) async throws -> [ReadingSession] {
        let descriptor = FetchDescriptor<ReadingSessionModel>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt <= end },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return try modelContext.fetch(descriptor).map(ReadingSessionMapper.toEntity)
    }
}
