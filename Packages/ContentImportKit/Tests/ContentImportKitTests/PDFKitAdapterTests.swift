import Foundation
import Testing
import ContentImportKit
import Domain
import AppKit
import CoreGraphics

@Suite("PDFKitAdapter")
struct PDFKitAdapterTests {
    @Test("canHandle accepts pdf files only")
    func canHandlePDF() {
        let adapter = PDFKitAdapter()
        let pdf = URL(fileURLWithPath: "/tmp/sample.pdf")
        let txt = URL(fileURLWithPath: "/tmp/sample.txt")
        #expect(adapter.canHandle(.file(pdf)))
        #expect(!adapter.canHandle(.file(txt)))
        #expect(!adapter.canHandle(.url(URL(string: "https://example.com")!)))
        #expect(!adapter.canHandle(.plainText(title: nil, body: "x")))
    }

    @Test("imports text and page previews from a multi-page PDF")
    func importsTextAndPreviews() async throws {
        let url = try Self.writePDF(
            pages: [
                "First page. Hello Melingo.",
                "Second page. More learning text.",
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await PDFKitAdapter().importContent(from: .file(url))

        #expect(imported.document.sourceKind == .pdf)
        #expect(imported.document.title == url.deletingPathExtension().lastPathComponent)
        #expect(imported.stagingFileURL == url)
        #expect(imported.pagePreviews.count == 2)
        #expect(imported.pagePreviews[0].pageIndex == 0)
        #expect(!imported.pagePreviews[0].pngData.isEmpty)
        #expect(imported.segments.count >= 2)
        let joined = imported.segments.map(\.text).joined(separator: " ")
        #expect(joined.contains("First page"))
        #expect(joined.contains("Second page"))
    }

    @Test("router selects PDFKitAdapter for pdf files")
    func routerSelectsPDF() async throws {
        let url = try Self.writePDF(pages: ["Routed sentence one."])
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await ContentImportRouter().importContent(from: .file(url))
        #expect(imported.document.sourceKind == .pdf)
        #expect(!imported.segments.isEmpty)
    }

    /// Minimal single/multi-page PDF via Core Graphics.
    private static func writePDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-pdf-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ContentImportError.parseFailed("Could not create PDF context")
        }
        for text in pages {
            context.beginPDFPage(nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(
                rect: CGRect(x: 72, y: 72, width: 468, height: 648),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
