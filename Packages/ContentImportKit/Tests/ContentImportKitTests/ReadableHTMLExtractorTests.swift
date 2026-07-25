import Testing
import Foundation
@testable import ContentImportKit

@Suite("ReadableHTMLExtractor")
struct ReadableHTMLExtractorTests {
    @Test func extractsTitleAndArticleBody() {
        let html = """
        <html><head><title>Hello &amp; World</title></head>
        <body>
          <nav>Home About</nav>
          <article>
            <p>First paragraph of the story.</p>
            <p>Second paragraph continues here with more words for density.</p>
          </article>
          <footer>Copyright</footer>
        </body></html>
        """
        let url = URL(string: "https://example.com/a")!
        let result = ReadableHTMLExtractor.extract(html: html, pageURL: url)
        #expect(result.title == "Hello & World")
        #expect(result.content.contains("First paragraph"))
        #expect(result.content.contains("Second paragraph"))
        #expect(!result.content.contains("Copyright"))
    }

    @Test func fallbackUsesKashiAreaWhenShort() {
        let html = """
        <html><head><title>Song</title></head>
        <body>
          <div>Voting thanks</div>
          <div id="kashi_area">Line one<br>Line two<br>Line three<br>Line four<br>Line five<br>Line six<br>Line seven</div>
        </body></html>
        """
        let url = URL(string: "https://www.uta-net.com/song/1/")!
        let result = ReadableHTMLExtractor.extract(html: html, pageURL: url)
        #expect(result.content.contains("Line one"))
        #expect(result.content.contains("Line two"))
        #expect(result.usedFallback == true)
    }

    @Test func preservesLineBreaksFromBr() {
        let html = "<div>Alpha<br/>Beta<br>Gamma</div>"
        let text = ReadableHTMLExtractor.htmlToTextPreservingLayout(html)
        #expect(text.contains("Alpha"))
        #expect(text.contains("Beta"))
        #expect(text.split(separator: "\n").count >= 2)
    }

    @Test func decodeNumericEntities() {
        let decoded = ReadableHTMLExtractor.decodeEntities("caf&#233; &#x1F600;")
        #expect(decoded.contains("café"))
    }
}
