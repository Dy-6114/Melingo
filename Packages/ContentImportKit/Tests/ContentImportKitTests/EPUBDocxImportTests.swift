import Foundation
import Testing
import ContentImportKit
import Domain

@Suite("ReadiumAdapter")
struct ReadiumAdapterTests {
    @Test("canHandle epub only")
    func canHandle() {
        let adapter = ReadiumAdapter()
        #expect(adapter.canHandle(.file(URL(fileURLWithPath: "/tmp/a.epub"))))
        #expect(!adapter.canHandle(.file(URL(fileURLWithPath: "/tmp/a.pdf"))))
    }

    @Test("imports spine XHTML as segments")
    func importsEPUB() async throws {
        let epub = ZipBuilder.build(entries: [
            (
                "META-INF/container.xml",
                Data("""
                <?xml version="1.0"?>
                <container>
                  <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>
                """.utf8)
            ),
            (
                "OEBPS/content.opf",
                Data("""
                <?xml version="1.0"?>
                <package>
                  <metadata>
                    <dc:title>Basho Notes</dc:title>
                  </metadata>
                  <manifest>
                    <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine>
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                  </spine>
                </package>
                """.utf8)
            ),
            (
                "OEBPS/chap1.xhtml",
                Data("<html><body><p>古池や。蛙飛び込む。</p></body></html>".utf8)
            ),
            (
                "OEBPS/chap2.xhtml",
                Data("<html><body><p>Second chapter sentence.</p></body></html>".utf8)
            ),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString).epub")
        try epub.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await ReadiumAdapter().importContent(from: .file(url))
        #expect(imported.document.sourceKind == .epub)
        #expect(imported.document.title == "Basho Notes")
        let text = imported.segments.map(\.text).joined(separator: " ")
        #expect(text.contains("古池や"))
        #expect(text.contains("Second chapter"))
    }
}

@Suite("DocxImportAdapter")
struct DocxImportAdapterTests {
    @Test("extracts paragraphs from document.xml")
    func importsDOCX() async throws {
        let docx = ZipBuilder.build(entries: [
            (
                "word/document.xml",
                Data("""
                <?xml version="1.0"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body>
                    <w:p><w:r><w:t>Hello from DOCX.</w:t></w:r></w:p>
                    <w:p><w:r><w:t>Second paragraph here.</w:t></w:r></w:p>
                  </w:body>
                </w:document>
                """.utf8)
            ),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString).docx")
        try docx.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try await DocxImportAdapter().importContent(from: .file(url))
        #expect(imported.document.sourceKind == .docx)
        let text = imported.segments.map(\.text).joined(separator: " ")
        #expect(text.contains("Hello from DOCX"))
        #expect(text.contains("Second paragraph"))
    }
}

@Suite("ContentImportRouter")
struct ContentImportRouterTests {
    @Test("routes by extension across adapters")
    func routes() {
        let router = ContentImportRouter()
        #expect(router.asArray.contains { $0.canHandle(.file(URL(fileURLWithPath: "/x.epub"))) })
        #expect(router.asArray.contains { $0.canHandle(.file(URL(fileURLWithPath: "/x.docx"))) })
        #expect(router.asArray.contains { $0.canHandle(.file(URL(fileURLWithPath: "/x.png"))) })
        #expect(router.asArray.contains { $0.canHandle(.image(URL(fileURLWithPath: "/x.png"))) })
    }
}
