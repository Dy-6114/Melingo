import Foundation
import Observation
@preconcurrency import TDLibKit

/// Authorization / connection state exposed to SwiftUI.
public enum TelegramAuthPhase: String, Sendable, Equatable {
    case idle
    case waitCredentials
    case waitPhoneNumber
    case waitCode
    case waitPassword
    case waitRegistration
    case ready
    case closed
    case error
}

extension TelegramAuthPhase {
    /// Calm, non-technical status for UI.
    public var calmLabel: String {
        switch self {
        case .idle, .waitCredentials: return "One-time setup"
        case .waitPhoneNumber: return "Phone number"
        case .waitCode: return "Waiting for code"
        case .waitPassword: return "Password"
        case .waitRegistration: return "Registration needed"
        case .ready: return "Connected"
        case .closed: return "Signed out"
        case .error: return "Something went wrong"
        }
    }
}

/// TDLib client. Not MainActor-isolated — updates arrive on TDLib’s background queue.
/// UI state is always applied on the main queue to keep SwiftUI/`@Observable` happy.
@Observable
public final class TelegramClientService: @unchecked Sendable {
    public private(set) var phase: TelegramAuthPhase = .idle
    public private(set) var statusMessage: String = ""
    public private(set) var lastError: String?
    public private(set) var phoneHint: String?

    /// TDLib allows only **one** `td_receive` loop per process. Destroying the manager
    /// while that loop is blocked in `td_receive(10)` and creating another causes SIGSEGV.
    private static let sharedManager = TDLibClientManager()

    @ObservationIgnored private var client: TDLibClient?
    @ObservationIgnored private var credentials: TelegramCredentials?
    @ObservationIgnored private var startGate = StartGate()

    public init() {}

    public var isReady: Bool { phase == .ready }

    public func configure(credentials: TelegramCredentials) {
        self.credentials = credentials
        if phase == .idle || phase == .waitCredentials || phase == .closed || phase == .error {
            applyState(phase: .waitPhoneNumber, status: "Enter your phone number", error: nil)
        }
    }

    /// Start TDLib using `TelegramPaths.tdlibDirectory`.
    /// Safe to call again; reuses the existing client and the process-wide manager.
    public func start() async throws {
        TelegramPaths.ensureDirectories()
        guard let credentials, credentials.isValid else {
            applyState(phase: .waitCredentials, status: "Add api_id and api_hash", error: nil)
            throw TelegramKitError.notConfigured
        }

        if client != nil { return }

        try await startGate.withExclusive { [self] in
            if self.client != nil { return }

            self.applyState(phase: .idle, status: "Connecting…", error: nil)

            // IMPORTANT: do not touch actor-isolated state synchronously inside this
            // callback — TDLib invokes it on `client-N.update-handler` (crash: SIGTRAP).
            let created = Self.sharedManager.createClient { [weak self] data, tdClient in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.handleUpdateData(data, client: tdClient)
                }
            }
            self.client = created
        }
    }

    /// Close the current client and open a new one on the **same** manager
    /// (e.g. after changing api_id / api_hash). Never recreates the receive loop.
    public func restart() async throws {
        await closeAsync()
        // Give TDLib a beat to finish removing the closed client from the manager.
        try? await Task.sleep(for: .milliseconds(300))
        try await start()
    }

    public func submitPhoneNumber(_ phone: String) async throws {
        guard let client else { throw TelegramKitError.tdlib("Not started") }
        let cleaned = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw TelegramKitError.tdlib("Enter a phone number")
        }
        try await waitForAuthInput()
        _ = try await client.setAuthenticationPhoneNumber(
            phoneNumber: cleaned,
            settings: nil
        )
        applyState(phase: .waitCode, status: "Code sent to your phone", error: nil)
    }

    public func submitCode(_ code: String) async throws {
        guard let client else { throw TelegramKitError.tdlib("Not started") }
        _ = try await client.checkAuthenticationCode(
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func submitPassword(_ password: String) async throws {
        guard let client else { throw TelegramKitError.tdlib("Not started") }
        _ = try await client.checkAuthenticationPassword(password: password)
    }

    public func waitUntilReady() async throws {
        for _ in 0..<600 {
            if phase == .ready { return }
            if phase == .error || phase == .closed {
                throw TelegramKitError.tdlib(lastError ?? "Couldn’t sign in")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TelegramKitError.tdlib("Still waiting to connect — try again")
    }

    /// Wait until TDLib is ready for phone / code / password input — or already logged in.
    public func waitForAuthInput() async throws {
        for _ in 0..<100 {
            switch phase {
            case .waitPhoneNumber, .waitCode, .waitPassword, .waitRegistration, .ready:
                return
            case .error:
                throw TelegramKitError.tdlib(lastError ?? "Telegram error")
            case .closed:
                throw TelegramKitError.tdlib("Signed out")
            default:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw TelegramKitError.tdlib("Telegram is still starting — try again")
    }

    /// Soft close — keeps the process-wide receive loop alive.
    public func close() {
        Task { await closeAsync() }
    }

    public func closeAsync() async {
        let existing = client
        client = nil

        guard let existing else {
            applyState(phase: .closed, status: "Signed out", error: nil)
            return
        }

        do {
            _ = try await existing.close()
        } catch {
            try? existing.close(completion: { _ in })
        }

        // Wait until auth reports closed (manager removes the client on that update).
        for _ in 0..<40 {
            if phase == .closed { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        applyState(phase: .closed, status: "Signed out", error: nil)
    }

    /// Expose client for exporters (same process).
    public func requireClient() throws -> TDLibClient {
        guard let client, phase == .ready else {
            throw TelegramKitError.notAuthorized
        }
        return client
    }

    // MARK: - Updates

    private func handleUpdateData(_ data: Data, client: TDLibClient) {
        do {
            let update = try client.decoder.decode(Update.self, from: data)
            handle(update: update, client: client)
        } catch {
            // Ignore non-Update payloads; TDLib also emits responses here.
        }
    }

    private func handle(update: Update, client: TDLibClient) {
        switch update {
        case .updateAuthorizationState(let state):
            Task {
                await handleAuthorizationState(state.authorizationState, client: client)
            }
        default:
            break
        }
    }

    private func handleAuthorizationState(_ state: AuthorizationState, client: TDLibClient) async {
        do {
            switch state {
            case .authorizationStateWaitTdlibParameters:
                try await setParameters(client: client)
            case .authorizationStateWaitPhoneNumber:
                applyState(phase: .waitPhoneNumber, status: "Enter your phone number", error: nil)
            case .authorizationStateWaitCode:
                applyState(phase: .waitCode, status: "Enter the code from Telegram", error: nil)
            case .authorizationStateWaitPassword:
                applyState(phase: .waitPassword, status: "Enter your cloud password", error: nil)
            case .authorizationStateWaitRegistration:
                applyState(
                    phase: .waitRegistration,
                    status: "This number needs registration in Telegram first",
                    error: nil
                )
            case .authorizationStateReady:
                applyState(phase: .ready, status: "Connected", error: nil)
            case .authorizationStateClosing, .authorizationStateClosed:
                applyState(phase: .closed, status: "Signed out", error: nil)
            case .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode:
                applyState(
                    phase: .error,
                    status: "Email sign-in isn’t supported here",
                    error: "Email sign-in isn’t supported here"
                )
            default:
                break
            }
        } catch {
            applyState(phase: .error, status: error.localizedDescription, error: error.localizedDescription)
        }
    }

    private func setParameters(client: TDLibClient) async throws {
        guard let credentials else { throw TelegramKitError.notConfigured }
        let dir = TelegramPaths.tdlibDirectory.path
        let files = TelegramPaths.tdlibDirectory.appendingPathComponent("files", isDirectory: true).path
        try FileManager.default.createDirectory(
            at: TelegramPaths.tdlibDirectory.appendingPathComponent("files", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try await client.setTdlibParameters(
            apiHash: credentials.apiHash,
            apiId: credentials.apiId,
            applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            databaseDirectory: dir,
            databaseEncryptionKey: Data(),
            deviceModel: "Mac",
            filesDirectory: files,
            systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            useChatInfoDatabase: true,
            useFileDatabase: true,
            useMessageDatabase: true,
            useSecretChats: false,
            useTestDc: false
        )
    }

    private func applyState(phase: TelegramAuthPhase, status: String, error: String?) {
        let apply = {
            self.phase = phase
            self.statusMessage = status
            self.lastError = error
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}

/// Serializes `start()` so two UI surfaces don’t create two TDLib clients at once.
private actor StartGate {
    func withExclusive(_ body: @Sendable () async throws -> Void) async throws {
        try await body()
    }
}
