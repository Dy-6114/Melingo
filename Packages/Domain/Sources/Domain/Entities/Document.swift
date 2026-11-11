import Foundation

public enum DocumentSourceKind: String, Codable, Sendable, CaseIterable {
    case plainText
    case markdown
    case web
    case pdf
    case epub
    case docx
    case imageOCR
    case youtube
}

/// Imported reading material. Framework-free value type (TZ §6.1).
public struct Document: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var sourceKind: DocumentSourceKind
    public var sourceURL: String?
    /// Relative path under `~/Documents/Melingo` for original binary (if any).
    public var storedFileRelativePath: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        sourceKind: DocumentSourceKind,
        sourceURL: String? = nil,
        storedFileRelativePath: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.storedFileRelativePath = storedFileRelativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
