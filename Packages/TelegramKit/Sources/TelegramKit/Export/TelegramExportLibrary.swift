import Foundation

/// Lists channel folders under `~/Documents/Melingo/Telegram/Exports`.
public enum TelegramExportLibrary {
    public struct Entry: Identifiable, Sendable, Hashable {
        public var id: String { folderURL.path }
        public var name: String
        public var folderURL: URL
        public var postCount: Int?
        public var title: String?

        public init(name: String, folderURL: URL, postCount: Int? = nil, title: String? = nil) {
            self.name = name
            self.folderURL = folderURL
            self.postCount = postCount
            self.title = title
        }
    }

    public static func listEntries() -> [Entry] {
        TelegramPaths.ensureDirectories()
        let fm = FileManager.default
        let root = TelegramPaths.exportsDirectory
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return kids.compactMap { url -> Entry? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let json = url.appendingPathComponent("channel.json")
            var title: String?
            var count: Int?
            if let data = try? Data(contentsOf: json),
               let doc = try? JSONDecoder.iso8601.decode(ChannelExportDocument.self, from: data)
            {
                title = doc.channel.title
                count = doc.posts.count
            }
            return Entry(
                name: url.lastPathComponent,
                folderURL: url,
                postCount: count,
                title: title
            )
        }
        .sorted { ($0.title ?? $0.name).localizedCaseInsensitiveCompare($1.title ?? $1.name) == .orderedAscending }
    }

    public static func loadDocument(at folder: URL) throws -> ChannelExportDocument {
        let json = folder.appendingPathComponent("channel.json")
        let data = try Data(contentsOf: json)
        return try JSONDecoder.iso8601.decode(ChannelExportDocument.self, from: data)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
