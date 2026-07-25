import Foundation
import Domain

/// Fetches a web page and extracts main text the same way as desktop
/// `fetch_url_content`: browser-like request → readability-lite → CSS fallback
/// → layout-preserving HTML→text → sentence segmentation.
public struct URLImportAdapter: ContentImporting, Sendable {
    private let segmenter: SentenceSegmenter
    private let session: URLSession

    public init(segmenter: SentenceSegmenter = SentenceSegmenter(), session: URLSession = .shared) {
        self.segmenter = segmenter
        self.session = session
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        if case .url = source { return true }
        return false
    }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        guard case .url(let url) = source else { throw ContentImportError.unsupportedSource }

        guard url.scheme == "http" || url.scheme == "https" else {
            throw ContentImportError.unsupportedSource
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        // Browser-like headers (desktop parity) to reduce bot blocking.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6,ru;q=0.5", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ContentImportError.networkFailed
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ContentImportError.networkFailed
        }

        let html = DocumentTextImporter.decodeText(data)
        let extracted = ReadableHTMLExtractor.extract(html: html, pageURL: url)
        let trimmed = extracted.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { throw ContentImportError.emptyContent }

        let document = Document(
            title: extracted.title.isEmpty ? (url.host ?? "Web") : extracted.title,
            sourceKind: .web,
            sourceURL: url.absoluteString
        )
        let drafts = segmenter.segment(trimmed)
        let segments = drafts.enumerated().map { index, draft in
            TextSegment(
                documentID: document.id,
                order: index,
                text: draft.text,
                isNewParagraph: draft.isNewParagraph
            )
        }
        return ImportedContent(
            document: document,
            segments: segments,
            illustrations: extracted.illustrations
        )
    }
}

/// Aggregates importers (Strategy) for the composition root.
///
/// This is the unified content-import strategy used by the Mac app UI: callers pass an
/// `ImportSource`; the first adapter whose `canHandle` matches performs extraction.
public struct ContentImportRouter: Sendable {
    private let importers: [any ContentImporting]

    public init(importers: [any ContentImporting]? = nil) {
        self.importers = importers ?? [
            DocumentTextImporter(),
            PDFKitAdapter(),
            ReadiumAdapter(),
            DocxImportAdapter(),
            VisionKitAdapter(),
            URLImportAdapter(),
        ]
    }

    public var asArray: [any ContentImporting] { importers }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        guard let importer = importers.first(where: { $0.canHandle(source) }) else {
            throw ContentImportError.unsupportedSource
        }
        return try await importer.importContent(from: source)
    }
}
