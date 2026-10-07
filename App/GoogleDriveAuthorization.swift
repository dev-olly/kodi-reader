import AppKit
import CryptoKit
import Darwin
import EpubKit
import Foundation
import Security

/// Drive consent is separate from Ask AI's Supabase Google sign-in.
@MainActor
final class GoogleDriveAuthorization: GoogleDriveCredentialProvider {
    private enum AuthorizationError: LocalizedError {
        case browserUnavailable
        case callbackInvalid
        case tokenExchange(Int, String?)
        case tokenResponseInvalid
        case refreshTokenMissing
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .browserUnavailable:
                "Could not open the Google sign-in page. Please try again."
            case .callbackInvalid:
                "Google sign-in did not return a valid confirmation to Kodi. Please try again."
            case let .tokenExchange(status, code):
                "Google rejected the Drive connection (HTTP \(status)\(code.map { ", \($0)" } ?? "")). Please try again."
            case .tokenResponseInvalid:
                "Google returned an incomplete Drive connection response. Please try again."
            case .refreshTokenMissing:
                "Google did not grant offline Drive access. Remove Kodi Reader’s access in your Google Account and connect again."
            case let .keychain(status):
                "Kodi could not save the Google Drive connection in Keychain (code \(status)). Try a signed build or check Keychain access."
            }
        }
    }

    private let clientID: String?
    private let clientSecret: String?
    private let session: URLSession
    private let keychainService = "com.olly.KodiReader.google-drive"
    private var currentToken: String?
    private var expiresAt = Date.distantPast

    var isConfigured: Bool { clientID != nil && clientSecret != nil }
    var isConnected: Bool { refreshToken != nil }

    init(clientID: String?, clientSecret: String?, session: URLSession = .shared) {
        let normalizedID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = normalizedID.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        let normalizedSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = normalizedSecret.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        self.session = session
    }

    func connect() async throws {
        guard let clientID, let clientSecret else { throw SyncFailure.googleNotConfigured }
        let verifier = try Self.randomURLSafe(count: 64)
        let state = try Self.randomURLSafe(count: 32)
        let listener = try LoopbackOAuthListener()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let redirect = "http://127.0.0.1:\(listener.port)/callback"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive.appdata"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let authorizationURL = url.url, NSWorkspace.shared.open(authorizationURL) else {
            listener.close()
            throw AuthorizationError.browserUnavailable
        }
        let callback = try await listener.waitForCallback()
        guard callback.state == state, let code = callback.code else { throw AuthorizationError.callbackInvalid }
        let response = try await exchange([
            "client_id": clientID, "client_secret": clientSecret, "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "grant_type": "authorization_code"
        ])
        guard let refresh = response.refresh_token else { throw AuthorizationError.refreshTokenMissing }
        try saveRefreshToken(refresh)
        let saved = readRefreshToken()
        guard saved.status == errSecSuccess, saved.token != nil else {
            throw AuthorizationError.keychain(saved.status)
        }
        currentToken = response.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(response.expires_in) - 60)
    }

    func accessToken() async throws -> String {
        if let currentToken, Date() < expiresAt { return currentToken }
        guard let clientID, let clientSecret else { throw SyncFailure.googleNotConfigured }
        guard let refreshToken else { throw SyncFailure.googleSignInRequired }
        let response = try await exchange([
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refreshToken, "grant_type": "refresh_token"
        ])
        if let replacement = response.refresh_token { try saveRefreshToken(replacement) }
        currentToken = response.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(response.expires_in) - 60)
        return response.access_token
    }

    func disconnect() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "refresh-token"]
        SecItemDelete(query as CFDictionary)
        currentToken = nil; expiresAt = .distantPast
    }

    private var refreshToken: String? {
        readRefreshToken().token
    }

    private func readRefreshToken() -> (token: String?, status: OSStatus) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "refresh-token",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    private func saveRefreshToken(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "refresh-token"]
        let data = Data(token.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw AuthorizationError.keychain(updated) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw AuthorizationError.keychain(added) }
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Int
    }

    private func exchange(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthorizationError.tokenResponseInvalid }
        guard http.statusCode == 200 else {
            let oauthCode = (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))?.error
            let safeCode = oauthCode.flatMap { Self.safeOAuthErrorCode($0) }
            throw AuthorizationError.tokenExchange(http.statusCode, safeCode)
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthorizationError.tokenResponseInvalid
        }
        return token
    }

    private struct OAuthErrorResponse: Decodable { let error: String }

    private static func safeOAuthErrorCode(_ code: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return code.count <= 64 && code.unicodeScalars.allSatisfy(allowed.contains) ? code : nil
    }

    private static func randomURLSafe(count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SyncFailure.googleSignInRequired
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A single-use listener bound to loopback, never to an external interface.
private final class LoopbackOAuthListener: @unchecked Sendable {
    let socketFD: Int32
    let port: UInt16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SyncFailure.googleSignInRequired }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd); throw SyncFailure.googleSignInRequired
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard named == 0 else { Darwin.close(fd); throw SyncFailure.googleSignInRequired }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    struct Callback: Sendable { var code: String?; var state: String? }

    func close() { Darwin.close(socketFD) }

    func waitForCallback() async throws -> Callback {
        try await Task.detached { [socketFD] in
            defer { Darwin.close(socketFD) }
            var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pollFD, 1, 120_000) > 0 else { throw SyncFailure.googleSignInRequired }
            let client = Darwin.accept(socketFD, nil, nil)
            guard client >= 0 else { throw SyncFailure.googleSignInRequired }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) {
                Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0,
                                  socklen_t(MemoryLayout<timeval>.size))
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(client, &bytes, bytes.count)
            guard count > 0,
                  let request = String(bytes: bytes.prefix(count), encoding: .utf8),
                  let first = request.components(separatedBy: "\r\n").first,
                  first.hasPrefix("GET /callback?"),
                  let path = first.split(separator: " ").dropFirst().first,
                  let url = URL(string: "http://127.0.0.1" + path),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw SyncFailure.googleSignInRequired
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\nYou can return to Kodi Reader and close this tab."
            _ = response.withCString { Darwin.write(client, $0, strlen($0)) }
            return Callback(code: parts.queryItems?.first(where: { $0.name == "code" })?.value,
                            state: parts.queryItems?.first(where: { $0.name == "state" })?.value)
        }.value
    }
}
