import Foundation
import Domain
import UniformTypeIdentifiers
import Vision

#if canImport(AppKit)
import AppKit
#endif

/// OCR import from still images via Vision (`VNRecognizeTextRequest`).
///
/// Checklist name: VisionKitAdapter. On macOS, Vision handles image OCR;
/// VisionKit’s document camera is iOS-oriented.
public struct VisionKitAdapter: ContentImporting, Sendable {
    private let segmenter: SentenceSegmenter
    private let languages: [String]

    public init(
        segmenter: SentenceSegmenter = SentenceSegmenter(),
        languages: [String] = ["ja", "en", "zh-Hans", "zh-Hant", "ko", "ru"]
    ) {
        self.segmenter = segmenter
        self.languages = languages
    }

    public func canHandle(_ source: ImportSource) -> Bool {
        switch source {
        case .image:
            return true
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
                .contains(ext) { return true }
            return UTType(filenameExtension: ext)?.conforms(to: .image) == true
        case .plainText, .url:
            return false
        }
    }

    public func importContent(from source: ImportSource) async throws -> ImportedContent {
        let url: URL
        switch source {
        case .image(let imageURL), .file(let imageURL):
            url = imageURL
        case .plainText, .url:
            throw ContentImportError.unsupportedSource
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let body = try await recognizeText(at: url)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContentImportError.emptyContent }

        let title = url.deletingPathExtension().lastPathComponent
        let document = Document(
            title: title.isEmpty ? "OCR" : title,
            sourceKind: .imageOCR,
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
            stagingFileURL: url
        )
    }

    private func recognizeText(at url: URL) async throws -> String {
        #if canImport(AppKit)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw ContentImportError.unreadableFile
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(
                        throwing: ContentImportError.parseFailed(error.localizedDescription)
                    )
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap {
                    $0.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(
                    throwing: ContentImportError.parseFailed(error.localizedDescription)
                )
            }
        }
        #else
        throw ContentImportError.parseFailed("OCR requires AppKit on macOS.")
        #endif
    }
}
