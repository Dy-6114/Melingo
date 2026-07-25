import Foundation
import Domain
import UniformTypeIdentifiers

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Extracts plain text and page thumbnails from local PDF files via PDFKit.
///
/// Everyday `.pdf` only — Readium publication packages are handled separately (TECHNICAL_DECISIONS §2).
public struct PDFKitAdapter: ContentImporting, Sendable {
    public static let previewMaxEdge: CGFloat = 240
    /// Soft cap so multi-hundred-page books don’t explode Application Support.
    public static let maxPagePreviews = 200

    private let segmenter: SentenceSegmenter

    public init(segmenter: SentenceSegmenter = SentenceSegmenter()) {
        self.segmenter = segmenter
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        guard case .file(let url) = source else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .pdf) == true
    }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        guard case .file(let url) = source else {
            throw ContentImportError.unsupportedSource
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let extracted: ExtractedPDF
        do {
            extracted = try await Task.detached(priority: .userInitiated) {
                try Self.extract(from: url)
            }.value
        } catch let error as ContentImportError {
            throw error
        } catch {
            throw ContentImportError.parseFailed(error.localizedDescription)
        }

        let trimmed = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContentImportError.emptyContent }

        let title = url.deletingPathExtension().lastPathComponent
        let document = Document(
            title: title.isEmpty ? "PDF" : title,
            sourceKind: .pdf,
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
            stagingFileURL: url,
            pagePreviews: extracted.previews
        )
    }

    // MARK: - Extraction

    private struct ExtractedPDF: Sendable {
        var body: String
        var previews: [PagePreviewAsset]
    }

    private static func extract(from url: URL) throws -> ExtractedPDF {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(url: url) else {
            throw ContentImportError.unreadableFile
        }
        if pdf.isEncrypted, !pdf.unlock(withPassword: "") {
            throw ContentImportError.parseFailed("PDF is password-protected.")
        }

        let pageCount = pdf.pageCount
        guard pageCount > 0 else { throw ContentImportError.emptyContent }

        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)
        var previews: [PagePreviewAsset] = []
        previews.reserveCapacity(min(pageCount, maxPagePreviews))

        for index in 0..<pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let pageText = (page.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pageText.isEmpty {
                pageTexts.append(pageText)
            }
            if index < maxPagePreviews, let png = renderPreviewPNG(page: page) {
                previews.append(PagePreviewAsset(pageIndex: index, pngData: png))
            }
        }

        let body = pageTexts.joined(separator: "\n\n")
        return ExtractedPDF(body: body, previews: previews)
        #else
        throw ContentImportError.parseFailed("PDFKit is unavailable on this platform.")
        #endif
    }

    #if canImport(PDFKit) && canImport(AppKit)
    private static func renderPreviewPNG(page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = min(
            previewMaxEdge / bounds.width,
            previewMaxEdge / bounds.height,
            1
        )
        let size = CGSize(
            width: max(1, floor(bounds.width * scale)),
            height: max(1, floor(bounds.height * scale))
        )
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
    #endif
}
