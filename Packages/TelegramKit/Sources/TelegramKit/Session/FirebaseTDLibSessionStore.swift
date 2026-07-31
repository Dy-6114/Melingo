import Foundation
import CryptoKit

/// Syncs the local TDLib database directory to Firebase Realtime Database
/// so another machine can restore the same user session (no custom server).
public actor FirebaseTDLibSessionStore {
    public static let defaultDatabaseURL =
        "https://telegram-f549b-default-rtdb.europe-west1.firebasedatabase.app"

    private let databaseURL: URL
    private let session: URLSession
    private let chunkSize: Int

    public init(
        databaseURL: String = FirebaseTDLibSessionStore.defaultDatabaseURL,
        session: URLSession = .shared,
        chunkSize: Int = 700_000
    ) {
        var urlString = databaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if urlString.hasSuffix(".json") {
            urlString = String(urlString.dropLast(5))
        }
        self.databaseURL = URL(string: urlString)!
        self.session = session
        self.chunkSize = chunkSize
    }

    public struct SessionMeta: Codable, Sendable, Equatable {
        public var updatedAt: Date
        public var apiId: Int
        public var apiHash: String
        public var chunkCount: Int
        public var totalBytes: Int
        public var sha256: String
        public var phoneHint: String?

        public init(
            updatedAt: Date = .now,
            apiId: Int,
            apiHash: String,
            chunkCount: Int,
            totalBytes: Int,
            sha256: String,
            phoneHint: String? = nil
        ) {
            self.updatedAt = updatedAt
            self.apiId = apiId
            self.apiHash = apiHash
            self.chunkCount = chunkCount
            self.totalBytes = totalBytes
            self.sha256 = sha256
            self.phoneHint = phoneHint
        }
    }

    /// Upload zipped TDLib directory under `/tdlib_sessions/{sessionKey}`.
    public func upload(
        sessionKey: String,
        tdlibDirectory: URL,
        credentials: TelegramCredentials,
        phoneHint: String? = nil
    ) async throws {
        let zipURL = try Self.zipDirectory(tdlibDirectory)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let data = try Data(contentsOf: zipURL)
        let digest = SHA256.hash(data: data)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        let chunks = stride(from: 0, to: data.count, by: chunkSize).map { start -> String in
            let end = min(start + chunkSize, data.count)
            return data[start..<end].base64EncodedString()
        }

        let meta = SessionMeta(
            apiId: credentials.apiId,
            apiHash: credentials.apiHash,
            chunkCount: chunks.count,
            totalBytes: data.count,
            sha256: sha,
            phoneHint: phoneHint
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metaData = try encoder.encode(meta)
        try await put(path: "tdlib_sessions/\(sessionKey)/meta", body: metaData)

        for (index, chunk) in chunks.enumerated() {
            // Must be a JSON-encoded string — raw String is not a valid
            // JSONSerialization top-level object and aborts with SIGABRT.
            let payload = try JSONEncoder().encode(chunk)
            try await put(path: "tdlib_sessions/\(sessionKey)/chunks/\(index)", body: payload)
        }
    }

    /// Download session archive into `destinationDirectory` (replaces contents).
    @discardableResult
    public func download(
        sessionKey: String,
        destinationDirectory: URL
    ) async throws -> SessionMeta {
        let metaData = try await get(path: "tdlib_sessions/\(sessionKey)/meta")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(SessionMeta.self, from: metaData)

        var assembled = Data()
        assembled.reserveCapacity(meta.totalBytes)
        for index in 0..<meta.chunkCount {
            let chunkData = try await get(path: "tdlib_sessions/\(sessionKey)/chunks/\(index)")
            guard let b64 = try JSONSerialization.jsonObject(with: chunkData) as? String,
                  let part = Data(base64Encoded: b64)
            else {
                throw TelegramKitError.sessionSyncFailed("Invalid chunk \(index)")
            }
            assembled.append(part)
        }

        let digest = SHA256.hash(data: assembled)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        guard sha == meta.sha256 else {
            throw TelegramKitError.sessionSyncFailed("SHA-256 mismatch after download")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationDirectory.path) {
            try fm.removeItem(at: destinationDirectory)
        }
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdlib-restore-\(UUID().uuidString).zip")
        try assembled.write(to: zipURL)
        defer { try? fm.removeItem(at: zipURL) }
        try Self.unzip(zipURL, to: destinationDirectory)

        try TelegramCredentialStore.save(
            TelegramCredentials(apiId: meta.apiId, apiHash: meta.apiHash)
        )
        return meta
    }

    public func fetchMeta(sessionKey: String) async throws -> SessionMeta {
        let metaData = try await get(path: "tdlib_sessions/\(sessionKey)/meta")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionMeta.self, from: metaData)
    }

    /// Remove cloud session (`/tdlib_sessions/{sessionKey}`).
    public func deleteRemote(sessionKey: String) async throws {
        try await delete(path: "tdlib_sessions/\(sessionKey)")
    }

    /// Soft probe: returns meta or nil if missing (not a permission error).
    public func peekMeta(sessionKey: String) async throws -> SessionMeta? {
        do {
            return try await fetchMeta(sessionKey: sessionKey)
        } catch TelegramKitError.sessionSyncFailed(let message) where message.contains("not found") {
            return nil
        }
    }

    /// Keys under `/tdlib_sessions` (shallow list).
    public func listSessionKeys() async throws -> [String] {
        let url = databaseURL.appendingPathComponent("tdlib_sessions.json")
            .appending(queryItems: [URLQueryItem(name: "shallow", value: "true")])
        let (data, response) = try await session.data(from: url)
        try throwIfFirebaseDenied(response: response, data: data, action: "GET tdlib_sessions")
        if data == Data("null".utf8) { return [] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return object.keys.sorted()
    }

    // MARK: - HTTP

    private func put(path: String, body: Data) async throws {
        let url = databaseURL.appendingPathComponent("\(path).json")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try throwIfFirebaseDenied(response: response, data: data, action: "PUT \(path)")
    }

    private func get(path: String) async throws -> Data {
        let url = databaseURL.appendingPathComponent("\(path).json")
        let (data, response) = try await session.data(from: url)
        try throwIfFirebaseDenied(response: response, data: data, action: "GET \(path)")
        if data == Data("null".utf8) {
            throw TelegramKitError.sessionSyncFailed("Session '\(path)' not found")
        }
        return data
    }

    private func delete(path: String) async throws {
        let url = databaseURL.appendingPathComponent("\(path).json")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try throwIfFirebaseDenied(response: response, data: data, action: "DELETE \(path)")
    }

    private func throwIfFirebaseDenied(response: URLResponse, data: Data, action: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TelegramKitError.sessionSyncFailed("\(action) failed")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw TelegramKitError.sessionSyncFailed(
                "Firebase rules block access (HTTP \(http.statusCode)). Allow read/write under tdlib_sessions — see Packages/TelegramKit/firebase-database.rules.json"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TelegramKitError.sessionSyncFailed("\(action) failed (\(http.statusCode)) \(body.prefix(120))")
        }
    }

    // MARK: - Zip helpers

    private static func zipDirectory(_ directory: URL) throws -> URL {
        let fm = FileManager.default
        let zipURL = fm.temporaryDirectory
            .appendingPathComponent("tdlib-\(UUID().uuidString).zip")
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.path, "."]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TelegramKitError.sessionSyncFailed("zip failed")
        }
        return zipURL
    }

    private static func unzip(_ zipURL: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TelegramKitError.sessionSyncFailed("unzip failed")
        }
    }
}
