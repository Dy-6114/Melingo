import Foundation
import TelegramKit

@main
enum TelegramRemoteExporterMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        do {
            switch command {
            case "pull-session":
                let key = value(for: "--key", in: args) ?? TelegramPaths.loadOrCreateSessionKey()
                try await pullSession(key: key)
            case "push-session":
                let key = value(for: "--key", in: args) ?? TelegramPaths.loadOrCreateSessionKey()
                try await pushSession(key: key)
            case "export":
                guard let channel = value(for: "--channel", in: args) else {
                    fputs("Missing --channel @username\n", stderr)
                    exit(1)
                }
                let out = value(for: "--out", in: args).map { URL(fileURLWithPath: $0) }
                try await exportChannel(username: channel, output: out)
            case "help", "-h", "--help":
                printUsage()
            default:
                fputs("Unknown command: \(command)\n", stderr)
                printUsage()
                exit(1)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            telegram-export — restore Melingo TDLib session from Firebase and export channels.

            Usage:
              telegram-export pull-session [--key primary]
              telegram-export push-session [--key primary]
              telegram-export export --channel @username [--out /path/to/dir]

            Firebase: \(FirebaseTDLibSessionStore.defaultDatabaseURL)
            Local TDLib: ~/Documents/Melingo/Telegram/tdlib
            """
        )
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func pullSession(key: String) async throws {
        print("Downloading TDLib session '\(key)' from Firebase")
        let store = FirebaseTDLibSessionStore()
        TelegramPaths.ensureDirectories()
        let meta = try await store.download(
            sessionKey: key,
            destinationDirectory: TelegramPaths.tdlibDirectory
        )
        TelegramPaths.setSessionKey(key)
        try TelegramCredentialStore.save(
            TelegramCredentials(apiId: meta.apiId, apiHash: meta.apiHash)
        )
        let hint = meta.phoneHint.map { "phone hint: \($0)" } ?? "no phone hint"
        print("Restored session (\(meta.totalBytes) bytes, \(hint)")
        print("TDLib dir: \(TelegramPaths.tdlibDirectory.path)")
    }

    private static func pushSession(key: String) async throws {
        guard let creds = TelegramCredentialStore.load(), creds.isValid else {
            throw TelegramKitError.tdlib("Missing Telegram API credentials in Keychain.")
        }
        let store = FirebaseTDLibSessionStore()
        TelegramPaths.setSessionKey(key)
        try await store.upload(
            sessionKey: key,
            tdlibDirectory: TelegramPaths.tdlibDirectory,
            credentials: creds
        )
        print("Uploaded session '\(key)' to Firebase.")
    }

    private static func exportChannel(username: String, output: URL?) async throws {
        guard let creds = TelegramCredentialStore.load(), creds.isValid else {
            fputs("No API credentials. Run Melingo once, or set via pull-session.\n", stderr)
            throw TelegramKitError.notConfigured
        }

        let clientService = await MainActor.run { TelegramClientService() }
        try await MainActor.run { clientService.configure(credentials: creds) }
        print("Starting TDLib")
        try await clientService.start()
        try await clientService.waitUntilReady()
        let client = try await MainActor.run { try clientService.requireClient() }

        let name = ChannelExporter.normalizeUsername(username)
        print("Exporting @\(name)")
        let out = output ?? TelegramPaths.exportFolder(forUsername: name)
        let doc = try await ChannelExporter().export(
            username: name,
            client: client,
            outputDirectory: out
        ) { progress in
            fputs("\r\(progress.message)                    ", stderr)
            fflush(stderr)
        }
        fputs("\n", stderr)
        print("Done. \(doc.posts.count) posts → \(out.path)")
        await MainActor.run { clientService.close() }
    }
}
