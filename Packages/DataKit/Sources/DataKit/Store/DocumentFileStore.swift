import Foundation
import Domain

/// Binary originals live on disk; SwiftData only stores relative paths (TZ §9 / decision §5).
public struct DocumentFileStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    /// Relative path: `{documentID}/original.{ext}`
    public func relativePath(documentID: UUID, fileExtension: String) -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(documentID.uuidString)/original.\(ext)"
    }

    /// Relative path: `{documentID}/previews/page-{index}.png`
    public func pagePreviewRelativePath(documentID: UUID, pageIndex: Int) -> String {
        "\(documentID.uuidString)/previews/page-\(pageIndex).png"
    }

    public func absoluteURL(for relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath, isDirectory: false)
    }

    @discardableResult
    public func store(data: Data, documentID: UUID, fileExtension: String) throws -> String {
        let relative = relativePath(documentID: documentID, fileExtension: fileExtension)
        let url = absoluteURL(for: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return relative
    }

    /// Persists page thumbnails; returns relative paths in page order.
    @discardableResult
    public func storePagePreviews(
        _ previews: [(pageIndex: Int, pngData: Data)],
        documentID: UUID
    ) throws -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(previews.count)
        for preview in previews.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            let relative = pagePreviewRelativePath(documentID: documentID, pageIndex: preview.pageIndex)
            let url = absoluteURL(for: relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try preview.pngData.write(to: url, options: .atomic)
            paths.append(relative)
        }
        return paths
    }

    public func pagePreviewURL(documentID: UUID, pageIndex: Int) -> URL? {
        let relative = pagePreviewRelativePath(documentID: documentID, pageIndex: pageIndex)
        let url = absoluteURL(for: relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func pagePreviewCount(for documentID: UUID) -> Int {
        let dir = rootDirectory
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return 0
        }
        return names.filter { $0.hasPrefix("page-") && $0.hasSuffix(".png") }.count
    }

    // MARK: - Article scenes (illustrations)

    private func scenesDirectory(documentID: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
            .appendingPathComponent("scenes", isDirectory: true)
    }

    private func scenesManifestURL(documentID: UUID) -> URL {
        scenesDirectory(documentID: documentID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    /// Persists illustration metadata (+ optional downloaded bytes named `{id}.img`).
    public func storeIllustrations(_ items: [ArticleIllustration], documentID: UUID) throws {
        let dir = scenesDirectory(documentID: documentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: scenesManifestURL(documentID: documentID), options: .atomic)
    }

    public func loadIllustrations(documentID: UUID) -> [ArticleIllustration] {
        let url = scenesManifestURL(documentID: documentID)
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ArticleIllustration].self, from: data)
        else { return [] }
        return items
    }

    public func sceneImageURL(documentID: UUID, illustrationID: UUID) -> URL? {
        let url = scenesDirectory(documentID: documentID)
            .appendingPathComponent("\(illustrationID.uuidString).img", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func storeSceneImage(data: Data, documentID: UUID, illustrationID: UUID) throws -> URL {
        let dir = scenesDirectory(documentID: documentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(illustrationID.uuidString).img", isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func deleteAll(for documentID: UUID) throws {
        let dir = rootDirectory.appendingPathComponent(documentID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    public func read(relativePath: String) throws -> Data {
        try Data(contentsOf: absoluteURL(for: relativePath))
    }

    /// Relative path under `Audio/{entryID}.m4a` (or given extension).
    @discardableResult
    public func storeAudio(data: Data, entryID: UUID, fileExtension: String = "m4a") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let relative = "Audio/\(entryID.uuidString).\(ext)"
        let url = absoluteURL(for: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return relative
    }

    @discardableResult
    public func storeCover(data: Data, packID: UUID, fileExtension: String = "jpg") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let relative = "Covers/\(packID.uuidString).\(ext)"
        let url = absoluteURL(for: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return relative
    }

    @discardableResult
    public func storeAvatar(data: Data, fileExtension: String = "jpg") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let relative = "Avatar/profile.\(ext)"
        let url = absoluteURL(for: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return relative
    }

    public func deleteRelativePath(_ relativePath: String) throws {
        let url = absoluteURL(for: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
