import Foundation

public enum ImportSource: Sendable, Hashable {
    case file(URL)
    case url(URL)
    case plainText(title: String?, body: String)
    case image(URL)
}

/// Raster preview of a source page (e.g. PDF), staged until DataKit persists it.
public struct PagePreviewAsset: Sendable, Hashable {
    public var pageIndex: Int
    public var pngData: Data

    public init(pageIndex: Int, pngData: Data) {
        self.pageIndex = pageIndex
        self.pngData = pngData
    }
}

/// Inline article illustration extracted from HTML (hero + between-paragraph scenes).
public struct ArticleIllustration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var remoteURL: String
    public var altText: String?
    /// Insert after this paragraph index (0-based). `-1` = hero before body.
    public var afterParagraphIndex: Int

    public init(
        id: UUID = UUID(),
        remoteURL: String,
        altText: String? = nil,
        afterParagraphIndex: Int = -1
    ) {
        self.id = id
        self.remoteURL = remoteURL
        self.altText = altText
        self.afterParagraphIndex = afterParagraphIndex
    }
}

/// Result of a successful import: document metadata + segmented body.
public struct ImportedContent: Sendable, Hashable {
    public var document: Document
    public var segments: [TextSegment]
    /// Absolute path to a staged original file before DataKit persists it.
    public var stagingFileURL: URL?
    /// Optional page thumbnails (PDF / EPUB later). Persisted under `{documentID}/previews/`.
    public var pagePreviews: [PagePreviewAsset]
    /// Web article scenes (OG / in-body images). Persisted under `{documentID}/scenes/`.
    public var illustrations: [ArticleIllustration]

    public init(
        document: Document,
        segments: [TextSegment],
        stagingFileURL: URL? = nil,
        pagePreviews: [PagePreviewAsset] = [],
        illustrations: [ArticleIllustration] = []
    ) {
        self.document = document
        self.segments = segments
        self.stagingFileURL = stagingFileURL
        self.pagePreviews = pagePreviews
        self.illustrations = illustrations
    }
}
