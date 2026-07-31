import SwiftUI
import TelegramKit
import Observation

/// Single shared Telegram session for the whole app (one TDLib db / one login).
@MainActor
enum TelegramSession {
    static let shared = TelegramWorkspaceController()
}

@MainActor
@Observable
final class TelegramWorkspaceController {
    let client = TelegramClientService()
    let sessionStore = FirebaseTDLibSessionStore()

    var apiIdText = ""
    var apiHashText = ""
    var phone = ""
    var code = ""
    var password = ""
    var channelUsername = ""
    var isBusy = false
    var progressText = ""
    var exportDocument: ChannelExportDocument?
    var exportDirectory: URL?
    var sessionKey: String = TelegramPaths.loadOrCreateSessionKey()
    var lastSyncMessage: String?
    var showSetup = false

    var needsSetup: Bool {
        TelegramCredentialStore.load()?.isValid != true
    }

    init() {
        if let creds = TelegramCredentialStore.load() {
            apiIdText = String(creds.apiId)
            apiHashText = creds.apiHash
            client.configure(credentials: creds)
            showSetup = false
        } else {
            showSetup = true
        }
    }

    /// Persist api_id / api_hash and open a TDLib session with those keys.
    func saveCredentialsAndStart() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let creds = try makeCredentials()
            try TelegramCredentialStore.save(creds)
            client.configure(credentials: creds)
            showSetup = false
            // Recreate only the client (same receive loop) so new keys apply.
            try await client.restart()
            try await client.waitForAuthInput()
            progressText = localizedStatus(for: client.phase)
        } catch {
            progressText = friendly(error)
            showSetup = true
        }
    }

    func saveCredentials() throws {
        let creds = try makeCredentials()
        try TelegramCredentialStore.save(creds)
        client.configure(credentials: creds)
        showSetup = false
    }

    private func makeCredentials() throws -> TelegramCredentials {
        let idText = apiIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashText = apiHashText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiId = Int(idText), apiId > 0 else {
            throw TelegramKitError.notConfigured
        }
        let creds = TelegramCredentials(apiId: apiId, apiHash: hashText)
        guard creds.isValid else { throw TelegramKitError.notConfigured }
        return creds
    }

    /// Soft connect: reuse an existing login from disk. Call when opening the Telegram tab.
    func ensureConnected() async {
        if client.isReady {
            progressText = localizedStatus(for: .ready)
            showSetup = false
            return
        }
        guard !needsSetup, let creds = TelegramCredentialStore.load() else {
            showSetup = true
            return
        }
        if isBusy { return }
        isBusy = true
        defer { isBusy = false }
        do {
            client.configure(credentials: creds)
            try await client.start()
            try await client.waitForAuthInput()
            // Already-authorized DB usually flips to ready within a second.
            for _ in 0..<40 {
                if client.isReady { break }
                if client.phase == .waitCode || client.phase == .waitPassword {
                    break
                }
                if client.phase == .waitPhoneNumber {
                    // Still warming; keep waiting a bit more for ready.
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            progressText = localizedStatus(for: client.phase)
            // Only force the setup sheet when keys are missing or auth truly needs input.
            showSetup = !client.isReady && (
                client.phase == .waitPhoneNumber
                    || client.phase == .waitCode
                    || client.phase == .waitPassword
                    || client.phase == .waitCredentials
                    || client.phase == .error
            )
        } catch {
            progressText = friendly(error)
            if needsSetup { showSetup = true }
        }
    }

    func startClient() async {
        // Soft path: keys already on disk — never tear down the session just to “start”.
        if !needsSetup, let creds = TelegramCredentialStore.load() {
            let formId = Int(apiIdText.trimmingCharacters(in: .whitespacesAndNewlines))
            let formHash = apiHashText.trimmingCharacters(in: .whitespacesAndNewlines)
            let keysUnchanged = (formId == nil || formId == creds.apiId)
                && (formHash.isEmpty || formHash == creds.apiHash)
            if keysUnchanged {
                showSetup = false
                await ensureConnected()
                return
            }
        }

        isBusy = true
        defer { isBusy = false }
        do {
            try saveCredentials()
            try await client.restart()
            try await client.waitForAuthInput()
            progressText = localizedStatus(for: client.phase)
        } catch {
            progressText = friendly(error)
            showSetup = true
        }
    }

    func startThenPhone() async {
        if !client.isReady && client.phase != .waitCode && client.phase != .waitPassword {
            await startClient()
        }
        if client.phase == .waitPhoneNumber || client.phase == .idle {
            await submitPhone()
        }
    }

    func submitPhone() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if client.phase == .idle || client.phase == .closed || client.phase == .waitCredentials {
                await startClient()
            }
            try await client.submitPhoneNumber(phone)
            progressText = AppL10n.t("import.telegram.status.codeSent")
        } catch {
            progressText = friendly(error)
        }
    }

    func submitCode() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.submitCode(code)
            // Allow auth state to settle.
            for _ in 0..<30 {
                if client.isReady || client.phase == .waitPassword || client.phase == .error {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            progressText = localizedStatus(for: client.phase)
            // Cloud sync is optional and must never interrupt sign-in.
            // (Previously Firebase JSON encoding aborted the process with SIGABRT.)
        } catch {
            progressText = friendly(error)
        }
    }

    func submitPassword() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.submitPassword(password)
            for _ in 0..<30 {
                if client.isReady || client.phase == .error {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            progressText = localizedStatus(for: client.phase)
        } catch {
            progressText = friendly(error)
        }
    }

    /// Firebase sync is optional — never crash / block sign-in if it fails.
    private func pushSessionQuietly() async {
        do {
            try await pushSessionThrowing()
            lastSyncMessage = AppL10n.t("import.telegram.sync.saved")
        } catch {
            lastSyncMessage = String(format: AppL10n.t("import.telegram.sync.saveFailed"), friendly(error))
        }
    }

    func pushSession() async {
        await pushSessionQuietly()
    }

    private func pushSessionThrowing() async throws {
        guard let creds = TelegramCredentialStore.load() else { return }
        TelegramPaths.setSessionKey(sessionKey)
        try await sessionStore.upload(
            sessionKey: sessionKey,
            tdlibDirectory: TelegramPaths.tdlibDirectory,
            credentials: creds,
            phoneHint: phone.isEmpty ? nil : String(phone.suffix(4))
        )
    }

    func pullSession() async {
        isBusy = true
        defer { isBusy = false }
        do {
            await client.closeAsync()
            // Wait for soft close before replacing session files.
            try? await Task.sleep(for: .milliseconds(400))
            _ = try await sessionStore.download(
                sessionKey: sessionKey,
                destinationDirectory: TelegramPaths.tdlibDirectory
            )
            TelegramPaths.setSessionKey(sessionKey)
            if let creds = TelegramCredentialStore.load() {
                apiIdText = String(creds.apiId)
                apiHashText = creds.apiHash
                client.configure(credentials: creds)
            }
            lastSyncMessage = AppL10n.t("import.telegram.sync.restored")
            try await client.start()
            try await client.waitUntilReady()
            progressText = AppL10n.t("import.telegram.status.connected")
        } catch {
            lastSyncMessage = friendly(error)
        }
    }

    func exportChannel(pageSize: Int = ChannelExporter.defaultPageSize) async {
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
            let doc = try await ChannelExporter(pageSize: pageSize).export(
                username: name,
                client: clientRef,
                outputDirectory: out
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.progressText = Self.localizedExportProgress(progress)
                }
            }
            exportDocument = doc
            exportDirectory = out
            progressText = String(format: AppL10n.t("import.telegram.progress.ready"), doc.posts.count)
        } catch {
            progressText = friendly(error)
            exportDocument = nil
        }
    }

    func exportMorePosts(existing: ChannelExportDocument) async -> ChannelExportDocument? {
        isBusy = true
        defer { isBusy = false }
        do {
            if !client.isReady {
                try await client.start()
                try await client.waitUntilReady()
            }
            let clientRef = try client.requireClient()
            let name = existing.channel.username
                ?? ChannelExporter.normalizeUsername(channelUsername)
            let out = TelegramPaths.exportsDirectory.appendingPathComponent(
                ChannelExporter.normalizeUsername(name),
                isDirectory: true
            )
            let doc = try await ChannelExporter(pageSize: ChannelExporter.defaultPageSize).exportMore(
                username: name,
                existing: existing,
                client: clientRef,
                outputDirectory: out
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.progressText = Self.localizedExportProgress(progress)
                }
            }
            exportDocument = doc
            exportDirectory = out
            progressText = String(format: AppL10n.t("import.telegram.progress.ready"), doc.posts.count)
            return doc
        } catch {
            progressText = friendly(error)
            return nil
        }
    }

    /// Merge newest posts into an existing export (keeps older pages).
    func exportNewestPosts(existing: ChannelExportDocument) async -> ChannelExportDocument? {
        isBusy = true
        defer { isBusy = false }
        do {
            if !client.isReady {
                try await client.start()
                try await client.waitUntilReady()
            }
            let clientRef = try client.requireClient()
            let name = existing.channel.username
                ?? ChannelExporter.normalizeUsername(channelUsername)
            let out = TelegramPaths.exportsDirectory.appendingPathComponent(
                ChannelExporter.normalizeUsername(name),
                isDirectory: true
            )
            let doc = try await ChannelExporter(pageSize: ChannelExporter.defaultPageSize).exportNewest(
                username: name,
                existing: existing,
                client: clientRef,
                outputDirectory: out
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.progressText = Self.localizedExportProgress(progress)
                }
            }
            exportDocument = doc
            exportDirectory = out
            progressText = String(format: AppL10n.t("import.telegram.progress.ready"), doc.posts.count)
            return doc
        } catch {
            progressText = friendly(error)
            return nil
        }
    }

    private static func localizedExportProgress(_ progress: ChannelExporter.Progress) -> String {
        let message = progress.message
        if progress.fetched == 0 || message.hasPrefix("Resolving") {
            return AppL10n.t("import.telegram.progress.resolving")
        }
        if message.hasPrefix("Processing") {
            return String(format: AppL10n.t("import.telegram.progress.processing"), progress.fetched)
        }
        return String(format: AppL10n.t("import.telegram.progress.fetched"), progress.fetched)
    }

    func localizedStatus(for phase: TelegramAuthPhase) -> String {
        switch phase {
        case .idle, .waitCredentials:
            return AppL10n.t("import.telegram.phase.setup")
        case .waitPhoneNumber:
            return AppL10n.t("import.telegram.status.enterPhone")
        case .waitCode:
            return AppL10n.t("import.telegram.status.enterCode")
        case .waitPassword:
            return AppL10n.t("import.telegram.status.enterPassword")
        case .waitRegistration:
            return AppL10n.t("import.telegram.status.needRegistration")
        case .ready:
            return AppL10n.t("import.telegram.status.connected")
        case .closed:
            return AppL10n.t("import.telegram.status.signedOut")
        case .error:
            return AppL10n.t("import.telegram.error")
        }
    }

    func friendly(_ error: Error) -> String {
        if let e = error as? TelegramKitError {
            switch e {
            case .notConfigured:
                return AppL10n.t("import.telegram.error.notConfigured")
            case .notAuthorized:
                return AppL10n.t("import.telegram.error.notAuthorized")
            case .channelNotFound(let name):
                return String(format: AppL10n.t("import.telegram.error.channelNotFound"), name)
            case .exportFailed(let msg):
                if msg.isEmpty { return AppL10n.t("import.telegram.error.exportFailed") }
                return mapRawTelegramMessage(msg) ?? AppL10n.t("import.telegram.error.exportFailed")
            case .sessionSyncFailed:
                return AppL10n.t("import.telegram.error.sessionSync")
            case .tdlib(let msg):
                return mapRawTelegramMessage(msg) ?? AppL10n.t("import.telegram.error")
            }
        }
        if let mapped = mapRawTelegramMessage(error.localizedDescription) {
            return mapped
        }
        return (error as? LocalizedError)?.errorDescription ?? AppL10n.t("import.telegram.error")
    }

    /// Friendly copy for a raw TDLib / client status string shown in the UI.
    func friendlyMessage(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AppL10n.t("import.telegram.error")
        }
        return mapRawTelegramMessage(raw) ?? AppL10n.t("import.telegram.error")
    }

    /// Maps raw TDLib / network strings into clear next steps for the user.
    private func mapRawTelegramMessage(_ raw: String) -> String? {
        let upper = raw.uppercased()
        if upper.contains("PHONE_NUMBER_INVALID") || upper.contains("PHONE NUMBER INVALID") {
            return AppL10n.t("import.telegram.error.invalidPhone")
        }
        if upper.contains("PHONE_CODE_INVALID")
            || upper.contains("PHONE_CODE_EXPIRED")
            || upper.contains("CODE_INVALID") {
            return AppL10n.t("import.telegram.error.invalidCode")
        }
        if upper.contains("PASSWORD") && (upper.contains("INVALID") || upper.contains("HASH")) {
            return AppL10n.t("import.telegram.error.invalidPassword")
        }
        if upper.contains("FLOOD") || upper.contains("TOO MANY") {
            return AppL10n.t("import.telegram.error.flood")
        }
        if upper.contains("NOT STARTED")
            || upper.contains("STILL WAITING")
            || upper.contains("STILL STARTING") {
            return AppL10n.t("import.telegram.error.tryAgain")
        }
        if upper.contains("NOT CONFIGURED")
            || upper.contains("CREDENTIAL")
            || upper.contains("API_ID")
            || upper.contains("API ID") {
            return AppL10n.t("import.telegram.error.notConfigured")
        }
        if upper.contains("NOT AUTHORIZED") || upper.contains("SIGNED OUT") {
            return AppL10n.t("import.telegram.error.notAuthorized")
        }
        if upper.contains("CHANNEL") && upper.contains("NOT FOUND") {
            return AppL10n.t("import.telegram.error.channelNotFound").replacingOccurrences(of: "%@", with: "…")
        }
        // Don't surface raw English/TDLib jargon if we couldn't map it.
        if raw.range(of: #"[A-Z]{3,}_[A-Z_]+"#, options: .regularExpression) != nil {
            return AppL10n.t("import.telegram.error")
        }
        return nil
    }
}

extension TelegramKitError: @retroactive LocalizedError {
    public var errorDescription: String? {
        // Prefer the controller’s friendly mapping when available; this is a fallback
        // for places that only show LocalizedError without going through friendly(_:).
        switch self {
        case .notConfigured:
            return AppL10n.t("import.telegram.error.notConfigured")
        case .notAuthorized:
            return AppL10n.t("import.telegram.error.notAuthorized")
        case .channelNotFound(let name):
            return String(format: AppL10n.t("import.telegram.error.channelNotFound"), name)
        case .exportFailed(let msg):
            return msg.isEmpty ? AppL10n.t("import.telegram.error.exportFailed") : msg
        case .sessionSyncFailed:
            return AppL10n.t("import.telegram.error.sessionSync")
        case .tdlib:
            return AppL10n.t("import.telegram.error")
        }
    }
}
