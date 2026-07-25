import Foundation

public struct FetchLibraryUseCase: Sendable {
    private let library: any LibraryRepository

    public init(library: any LibraryRepository) {
        self.library = library
    }

    public func callAsFunction() async throws -> [Document] {
        try await library.fetchDocuments()
    }
}
