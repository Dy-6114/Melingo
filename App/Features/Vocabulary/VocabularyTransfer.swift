import CoreTransferable
import UniformTypeIdentifiers

/// Drag payload for vocabulary → pack (single Transferable, no DropRegion zoo).
struct VocabularyTransfer: Codable, Transferable, Hashable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
