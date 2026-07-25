import Foundation

public enum DataPersistenceError: Error, Sendable, Equatable {
    case notFound
    case decodingFailed
    case encodingFailed
    case fileStoreFailed(String)
}
