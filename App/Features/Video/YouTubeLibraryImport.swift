import Foundation
import Domain

@MainActor
enum YouTubeLibraryImport {
    static func importVideo(
        urlString: String,
        preferredLanguage: String?,
        store: AppLibraryStore
    ) async throws -> Document {
        guard let videoID = YouTubeURLParser.videoID(from: urlString) else {
            throw YouTubeSubtitleError.invalidURL
        }

        var languages: [String] = []
        if let preferredLanguage, !preferredLanguage.isEmpty {
            languages.append(preferredLanguage)
            let base = preferredLanguage.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let base, base.lowercased() != preferredLanguage.lowercased() {
                languages.append(base)
            }
        }
        let ui = AppL10n.code
        if !languages.contains(where: { $0.caseInsensitiveCompare(ui) == .orderedSame }) {
            languages.append(ui)
        }
        for extra in ["en", "fr", "ru", "es", "de", "pt"] {
            if !languages.contains(where: { $0.caseInsensitiveCompare(extra) == .orderedSame }) {
                languages.append(extra)
            }
        }

        let transcript = try await YouTubeSubtitleService.fetchTranscript(
            videoID: videoID,
            preferredLanguages: languages
        )

        let existing = store.documents.first {
            $0.sourceKind == .youtube
                && YouTubeURLParser.videoID(from: $0.sourceURL ?? "") == videoID
        }

        let documentID = existing?.id ?? UUID()
        let payload = YouTubeImportPayload(
            videoID: videoID,
            title: transcript.title,
            languageCode: transcript.languageCode,
            languageName: transcript.languageName,
            cues: transcript.cues
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        var document = Document(
            id: documentID,
            title: transcript.title,
            sourceKind: .youtube,
            sourceURL: YouTubeURLParser.canonicalURL(videoID: videoID),
            createdAt: existing?.createdAt ?? .now,
            updatedAt: .now
        )

        let segments = transcript.cues.enumerated().map { index, cue in
            TextSegment(
                id: cue.id,
                documentID: documentID,
                order: index,
                text: cue.text,
                isNewParagraph: true
            )
        }

        try await store.saveYouTubeVideo(document: &document, segments: segments, payloadData: data)
        return store.documents.first(where: { $0.id == documentID }) ?? document
    }

    static func loadPayload(for document: Document, store: AppLibraryStore) -> YouTubeImportPayload? {
        guard document.sourceKind == .youtube,
              let relative = document.storedFileRelativePath,
              let data = try? store.readDocumentFile(relativePath: relative)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(YouTubeImportPayload.self, from: data)
    }
}
