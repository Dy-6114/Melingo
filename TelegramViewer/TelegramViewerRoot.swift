import SwiftUI
import TelegramKit
import Observation

@MainActor
@Observable
final class ViewerController {
    let client = TelegramClientService()
    let sessionStore = FirebaseTDLibSessionStore()

    var exports: [TelegramExportLibrary.Entry] = []
    var selectedExportID: String?
    var openDocument: ChannelExportDocument?
    var openFolder: URL?

    var apiIdText = ""
    var apiHashText = ""
    var phone = ""
    var code = ""
    var password = ""
    var channelUsername = ""
    var sessionKey = TelegramPaths.loadOrCreateSessionKey()
    var isBusy = false
    var note = ""
    var showSetup = false
    var remoteMeta: FirebaseTDLibSessionStore.SessionMeta?
    var remoteStatus = "Not checked"

    init() {
        if let creds = TelegramCredentialStore.load() {
            apiIdText = String(creds.apiId)
            apiHashText = creds.apiHash
            client.configure(credentials: creds)
        } else {
            showSetup = true
        }
        refreshExports()
    }

    func refreshExports() {
        exports = TelegramExportLibrary.listEntries()
    }

    func refreshRemoteSession() async {
        do {
            if let meta = try await sessionStore.peekMeta(sessionKey: sessionKey) {
                remoteMeta = meta
                let when = meta.updatedAt.formatted(date: .abbreviated, time: .shortened)
                let hint = meta.phoneHint.map { "··\($0)" } ?? "—"
                remoteStatus = "Cloud: \(ByteCountFormatter.string(fromByteCount: Int64(meta.totalBytes), countStyle: .file)) · \(when) · phone \(hint)"
            } else {
                remoteMeta = nil
                remoteStatus = "No cloud session for “\(sessionKey)”"
            }
        } catch {
            remoteMeta = nil
            remoteStatus = error.localizedDescription
            note = error.localizedDescription
        }
    }

    func open(_ entry: TelegramExportLibrary.Entry) {
        selectedExportID = entry.id
        do {
            openDocument = try TelegramExportLibrary.loadDocument(at: entry.folderURL)
            openFolder = entry.folderURL
            note = ""
        } catch {
            note = "Couldn’t open this channel folder"
            openDocument = nil
            openFolder = nil
        }
    }

    func saveSetup() async {
        guard let apiId = Int(apiIdText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            note = "App ID should be a number"
            return
        }
        let creds = TelegramCredentials(
            apiId: apiId,
            apiHash: apiHashText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard creds.isValid else {
            note = "Add both App ID and App hash"
            return
        }
        do {
            try TelegramCredentialStore.save(creds)
            client.configure(credentials: creds)
            showSetup = false
            try await client.start()
            note = client.statusMessage
        } catch {
            note = error.localizedDescription
            showSetup = true
        }
    }

    func continueWithPhone() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if client.phase == .idle || client.phase == .closed || client.phase == .waitCredentials {
                if let creds = TelegramCredentialStore.load() {
                    client.configure(credentials: creds)
                }
                try await client.start()
            }
            try await client.submitPhoneNumber(phone)
            note = client.statusMessage
        } catch {
            note = error.localizedDescription
        }
    }

    func submitCode() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.submitCode(code)
            note = client.statusMessage
            if client.isReady { await saveLogin() }
        } catch {
            note = error.localizedDescription
        }
    }

    func submitPassword() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.submitPassword(password)
            note = client.statusMessage
            if client.isReady { await saveLogin() }
        } catch {
            note = error.localizedDescription
        }
    }

    func saveLogin() async {
        guard let creds = TelegramCredentialStore.load() else {
            note = "No local credentials — restore from cloud or set up App ID first"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            TelegramPaths.setSessionKey(sessionKey)
            try await sessionStore.upload(
                sessionKey: sessionKey,
                tdlibDirectory: TelegramPaths.tdlibDirectory,
                credentials: creds,
                phoneHint: phone.isEmpty ? nil : String(phone.suffix(4))
            )
            note = "Login saved to Firebase"
            await refreshRemoteSession()
        } catch {
            note = error.localizedDescription
        }
    }

    func restoreLogin() async {
        isBusy = true
        defer { isBusy = false }
        do {
            client.close()
            let meta = try await sessionStore.download(
                sessionKey: sessionKey,
                destinationDirectory: TelegramPaths.tdlibDirectory
            )
            TelegramPaths.setSessionKey(sessionKey)
            if let creds = TelegramCredentialStore.load() {
                apiIdText = String(creds.apiId)
                apiHashText = creds.apiHash
                client.configure(credentials: creds)
            }
            try await client.start()
            try await client.waitUntilReady()
            note = "Restored · phone ··\(meta.phoneHint ?? "?") · connected"
            showSetup = false
            remoteMeta = meta
            await refreshRemoteSession()
        } catch {
            note = error.localizedDescription
        }
    }

    func deleteRemoteSession() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await sessionStore.deleteRemote(sessionKey: sessionKey)
            remoteMeta = nil
            remoteStatus = "Cloud session deleted"
            note = "Removed tdlib_sessions/\(sessionKey) from Firebase"
        } catch {
            note = error.localizedDescription
        }
    }

    func clearLocalSession() {
        client.close()
        let dir = TelegramPaths.tdlibDirectory
        try? FileManager.default.removeItem(at: dir)
        TelegramPaths.ensureDirectories()
        note = "Local TDLib folder cleared — restore from cloud or sign in again"
    }

    func fetchChannel() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if !client.isReady {
                try await client.start()
                try await client.waitUntilReady()
            }
            let clientRef = try client.requireClient()
            let name = ChannelExporter.normalizeUsername(channelUsername)
            let out = TelegramPaths.exportsDirectory.appendingPathComponent(name, isDirectory: true)
            let doc = try await ChannelExporter().export(
                username: name,
                client: clientRef,
                outputDirectory: out
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.note = progress.message
                        .replacingOccurrences(of: "Fetched", with: "Loading")
                        .replacingOccurrences(of: "Wrote", with: "Saved")
                }
            }
            refreshExports()
            openDocument = doc
            openFolder = out
            selectedExportID = out.path
            note = "\(doc.posts.count) posts ready"
            await saveLogin()
        } catch {
            note = error.localizedDescription
        }
    }
}

struct TelegramViewerRoot: View {
    @State private var controller = ViewerController()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .background(Color(tg: TelegramChrome.chatBackground))
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { controller.selectedExportID },
            set: { id in
                controller.selectedExportID = id
                if let id, let entry = controller.exports.first(where: { $0.id == id }) {
                    controller.open(entry)
                }
            }
        )) {
            Section("Cloud session (dev)") {
                TextField("Shared name", text: $controller.sessionKey)
                    .textFieldStyle(.roundedBorder)
                Text(controller.remoteStatus)
                    .font(.caption2)
                    .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
                    .textSelection(.enabled)
                Button("Check cloud") {
                    Task { await controller.refreshRemoteSession() }
                }
                .disabled(controller.isBusy)
                Button("Restore from Firebase") {
                    Task { await controller.restoreLogin() }
                }
                .disabled(controller.isBusy)
                Button("Push local → Firebase") {
                    Task { await controller.saveLogin() }
                }
                .disabled(controller.isBusy)
                Button("Delete cloud session", role: .destructive) {
                    Task { await controller.deleteRemoteSession() }
                }
                .disabled(controller.isBusy)
                Button("Clear local TDLib folder") {
                    controller.clearLocalSession()
                }
                Text("Path: tdlib_sessions/\(controller.sessionKey)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color(tg: TelegramChrome.serviceText))
            }

            Section("Saved channels") {
                if controller.exports.isEmpty {
                    Text("None yet")
                        .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
                }
                ForEach(controller.exports) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title ?? entry.name)
                            .font(.body.weight(.medium))
                        if let count = entry.postCount {
                            Text("\(count) posts")
                                .font(.caption)
                                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
                        }
                    }
                    .tag(entry.id)
                }
            }

            Section("Account") {
                accountBlock
            }

            Section("Open channel") {
                TextField("@username", text: $controller.channelUsername)
                    .textFieldStyle(.roundedBorder)
                Button(controller.isBusy ? "Loading…" : "Open") {
                    Task { await controller.fetchChannel() }
                }
                .disabled(
                    controller.isBusy
                        || !controller.client.isReady
                        || controller.channelUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(tg: TelegramChrome.headerBackground))
        .foregroundStyle(Color(tg: TelegramChrome.primaryText))
        .task {
            await controller.refreshRemoteSession()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    controller.refreshExports()
                    Task { await controller.refreshRemoteSession() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    @ViewBuilder
    private var accountBlock: some View {
        if controller.showSetup || TelegramCredentialStore.load() == nil {
            Text("First-time setup")
                .font(.caption)
                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
            TextField("App ID", text: $controller.apiIdText)
                .textFieldStyle(.roundedBorder)
            TextField("App hash", text: $controller.apiHashText)
                .textFieldStyle(.roundedBorder)
            Button("Save") { Task { await controller.saveSetup() } }
        }

        switch controller.client.phase {
        case .waitPhoneNumber, .idle, .waitCredentials, .closed:
            TextField("Phone", text: $controller.phone)
                .textFieldStyle(.roundedBorder)
            Button("Continue") { Task { await controller.continueWithPhone() } }
                .disabled(controller.phone.isEmpty)
        case .waitCode:
            TextField("Code", text: $controller.code)
                .textFieldStyle(.roundedBorder)
            Button("Confirm") { Task { await controller.submitCode() } }
        case .waitPassword:
            SecureField("Password", text: $controller.password)
                .textFieldStyle(.roundedBorder)
            Button("Confirm") { Task { await controller.submitPassword() } }
        case .ready:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(tg: TelegramChrome.accent))
                .font(.caption)
        default:
            Text(controller.client.phase.calmLabel)
                .font(.caption)
                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
        }

        if !controller.note.isEmpty {
            Text(controller.note)
                .font(.caption2)
                .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let doc = controller.openDocument {
            TelegramChannelBrowserView(document: doc, mediaRoot: controller.openFolder)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
                Text("Telegram Viewer")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(tg: TelegramChrome.primaryText))
                Text("Developer tool — not shipped with Melingo. Browse saved channels, restore a login, open public @channels.")
                    .font(.callout)
                    .foregroundStyle(Color(tg: TelegramChrome.secondaryText))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Text("DEV ONLY")
                    .font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(Color.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(tg: TelegramChrome.chatBackground))
        }
    }
}
