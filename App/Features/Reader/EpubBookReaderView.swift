import SwiftUI
import WebKit
import Domain
import ContentImportKit

/// Desktop-parity EPUB layout reader: TOC sidebar, chapter WebView, font size, prev/next.
/// Uses the ReadiumAdapter ZIP/OPF toolkit (same package path as import).
struct EpubBookReaderView: View {
    @Environment(AppLibraryStore.self) private var store
    @Environment(\.theme) private var theme

    let document: Document
    let bookURL: URL

    @State private var book: EPUBBook?
    @State private var chapterIndex = 0
    @State private var showTOC = true
    @State private var fontScale: Double = 1.0
    @State private var loadError: String?
    @State private var showStudy = false

    private var chapter: EPUBBook.Chapter? {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn’t open EPUB",
                    systemImage: "book.closed",
                    description: Text(loadError)
                )
            } else if showStudy {
                // Study reader fills the book column — not a floating sheet.
                ReaderView(document: document, onClose: { showStudy = false })
            } else if let book {
                reader(book)
            } else {
                ProgressView("Opening book…")
            }
        }
        .background(theme.background)
        .navigationTitle(book?.title ?? document.title)
        .toolbar {
            if !showStudy {
                ToolbarItemGroup {
                    Toggle(isOn: $showTOC) {
                        Image(systemName: "list.bullet")
                    }
                    .toggleStyle(.button)
                    .help("Table of contents")

                    Button {
                        chapterIndex = max(0, chapterIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(chapterIndex <= 0)
                    .help("Previous chapter")

                    Button {
                        if let book {
                            chapterIndex = min(book.chapters.count - 1, chapterIndex + 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(book.map { chapterIndex >= $0.chapters.count - 1 } ?? true)
                    .help("Next chapter")

                    Button {
                        fontScale = max(0.8, fontScale - 0.1)
                    } label: { Image(systemName: "textformat.size.smaller") }
                    .help("Smaller text")

                    Button {
                        fontScale = min(1.8, fontScale + 0.1)
                    } label: { Image(systemName: "textformat.size.larger") }
                    .help("Larger text")

                    Button {
                        showStudy = true
                    } label: {
                        Label("Study mode", systemImage: "character.textbox")
                    }
                    .help("Open immersive sentence / word study")
                }
            }
        }
        .task { await open() }
    }

    private func reader(_ book: EPUBBook) -> some View {
        HSplitView {
            if showTOC {
                List(selection: Binding(
                    get: { chapterIndex },
                    set: { chapterIndex = $0 }
                )) {
                    Section("Contents") {
                        ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                            Text(chapter.title)
                                .tag(index)
                                .foregroundStyle(theme.foreground)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(theme.card)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            }

            VStack(spacing: 0) {
                if let chapter {
                    Text(chapter.title)
                        .font(.headline)
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.card)
                    EPUBWebView(html: chapter.html, fontScale: fontScale)
                        .background(theme.background)
                }
                HStack {
                    Text("Chapter \(chapterIndex + 1) of \(book.chapters.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.mutedForeground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.card)
            }
            .frame(minWidth: 400)
        }
    }

    private func open() async {
        do {
            book = try ReadiumAdapter.openBook(at: bookURL)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct EPUBWebView: NSViewRepresentable {
    var html: String
    var fontScale: Double

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let scaled = html.replacingOccurrences(
            of: "line-height:1.65",
            with: "line-height:1.65;font-size:\(Int(17 * fontScale))px"
        )
        webView.loadHTMLString(scaled, baseURL: nil)
    }
}
