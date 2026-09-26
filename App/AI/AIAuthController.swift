import Auth
import AppKit
import AuthenticationServices
import Foundation
import Observation

enum AIAuthError: LocalizedError {
    case notConfigured, signInRequired

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Ask AI sign-in is not configured in this build."
        case .signInRequired: return "Sign in to use Ask AI."
        }
    }
}

/// One account session shared by every book. Reading data stays local.
@MainActor
@Observable
final class AIAuthController {
    private(set) var email: String?
    private(set) var userID: UUID?
    var showingSignIn = false
    private(set) var isChangingAccount = false
    var accountError: String?
    @ObservationIgnored var onWillSignOut: (() -> Void)?
    @ObservationIgnored private let client: AuthClient?
    @ObservationIgnored private let backendURL: URL
    @ObservationIgnored private let network: URLSession
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { email != nil }

    init(client: AuthClient? = AIAuthController.configuredClient(),
         backendURL: URL = URL(string: AIModelConfig.kodiHosted.baseURL)!, network: URLSession = .shared) {
        self.client = client
        self.backendURL = backendURL
        self.network = network
        email = client?.currentUser?.email
        userID = client?.currentUser?.id
        if let client {
            observationTask = Task { [weak self] in
                for await (_, session) in client.authStateChanges {
                    guard !Task.isCancelled else { break }
                    if session == nil, self?.email != nil { self?.onWillSignOut?() }
                    self?.email = session?.user.email
                    self?.userID = session?.user.id
                }
            }
        }
    }

    deinit { observationTask?.cancel() }

    nonisolated static func configuredClient(bundle: Bundle = .main) -> AuthClient? {
        guard let rawURL = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              !key.isEmpty, !key.contains("$("), !key.hasPrefix("sb_secret_") else { return nil }
        return AuthClient(
            url: url.appendingPathComponent("auth/v1"),
            headers: ["apikey": key],
            storageKey: "kodi-auth-\(url.host!)",
            localStorage: KeychainLocalStorage(service: "com.olly.KodiReader.auth"),
            emitLocalSessionAsInitialSession: true
        )
    }

    func sendCode(to email: String) async throws {
        guard let client else { throw AIAuthError.notConfigured }
        try await client.signInWithOTP(email: email, shouldCreateUser: true)
    }

    func verifyCode(_ code: String, email: String) async throws {
        guard let client else { throw AIAuthError.notConfigured }
        let response = try await client.verifyOTP(email: email, token: code, type: .email)
        guard let session = response.session else { throw AIAuthError.signInRequired }
        self.email = session.user.email
        self.userID = session.user.id
        showingSignIn = false
    }

    var googleEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "GoogleSignInEnabled") as? String == "YES" }
    var appleEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "AppleSignInEnabled") as? String == "YES" }

    func signInWithGoogle() async throws {
        guard googleEnabled else { throw AIAuthError.notConfigured }
        try await signInWithProvider(.google)
    }

    func signInWithApple() async throws {
        guard appleEnabled else { throw AIAuthError.notConfigured }
        try await signInWithProvider(.apple)
    }

    private func signInWithProvider(_ provider: Provider) async throws {
        guard let client else { throw AIAuthError.notConfigured }
        let browser = OAuthBrowserSession()
        let session = try await client.signInWithOAuth(provider: provider,
            redirectTo: URL(string: "com.olly.KodiReader://auth/callback"),
            launchFlow: { url in
                try await browser.authenticate(url: url, callbackScheme: "com.olly.KodiReader")
            })
        email = session.user.email
        userID = session.user.id
        showingSignIn = false
    }

    func accessToken() async throws -> String {
        guard let client else { throw AIAuthError.notConfigured }
        do {
            return try await client.session.accessToken
        } catch {
            // Refresh network failures leave the saved session and draft intact.
            if Self.requiresSignIn(error) {
                showingSignIn = true
                throw AIAuthError.signInRequired
            }
            throw error
        }
    }

    static func requiresSignIn(_ error: Error) -> Bool {
        guard let error = error as? AuthError else { return false }
        if case .sessionMissing = error { return true }
        let codes = ["refresh_token_not_found", "refresh_token_already_used", "session_not_found",
                     "session_expired", "user_not_found", "user_banned", "bad_jwt", "invalid_jwt"]
        return codes.contains(error.errorCode.rawValue)
    }

    func signOut() async {
        guard !isChangingAccount else { return }
        isChangingAccount = true
        onWillSignOut?()
        defer { isChangingAccount = false }
        // The SDK clears local storage before making the logout network request.
        // A network failure must not leave this Mac signed in.
        try? await client?.signOut(scope: .local)
        email = nil
        userID = nil
        accountError = nil
    }

    func deleteAccount() async {
        guard !isChangingAccount else { return }
        isChangingAccount = true
        accountError = nil
        onWillSignOut?()
        defer { isChangingAccount = false }
        do {
            let token = try await accessToken()
            var request = URLRequest(url: backendURL.appendingPathComponent("account"))
            request.httpMethod = "DELETE"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await network.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 {
                showingSignIn = true
                throw AIAuthError.signInRequired
            }
            guard http.statusCode == 204 else {
                throw AIChatError.http(http.statusCode, "Account deletion failed. Please try again.")
            }
            try? await client?.signOut(scope: .local)
            email = nil
            userID = nil
        } catch { accountError = error.localizedDescription }
    }
}

/// AuthenticationServices delivers completion on a background queue on macOS.
/// Creating this handler outside the main actor avoids the SDK convenience
/// wrapper's inherited actor assertion. Resuming a continuation is thread-safe;
/// the awaiting caller resumes on its own actor.
enum OAuthCallback {
    nonisolated static func handler(
        for continuation: CheckedContinuation<URL, Error>
    ) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let url {
                continuation.resume(returning: url)
            } else {
                continuation.resume(throwing: BrowserAuthError.missingCallback)
            }
        }
    }
}

private enum BrowserAuthError: LocalizedError {
    case missingCallback, couldNotStart

    var errorDescription: String? {
        switch self {
        case .missingCallback: return "Sign-in did not return a response. Please try again."
        case .couldNotStart: return "Could not open sign-in. Please try again."
        }
    }
}

@MainActor
private final class OAuthBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let anchor: NSWindow

    override init() {
        anchor = NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let browserSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: OAuthCallback.handler(for: continuation)
            )
            session = browserSession
            browserSession.presentationContextProvider = self
            if !browserSession.start() {
                continuation.resume(throwing: BrowserAuthError.couldNotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
