import Auth
import AuthenticationServices
import EpubKit
import Security
import XCTest

private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func retrieve(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class AIAuthenticationTests: XCTestCase {
    func testOAuthCallbackCanCompleteOnBackgroundQueue() async throws {
        let expected = URL(string: "com.olly.KodiReader://auth/callback?code=test-code")!
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            let completion = OAuthCallback.handler(for: continuation)
            DispatchQueue.global().async { completion(expected, nil) }
        }
        XCTAssertEqual(result, expected)
    }

    private func session(expired: Bool = false) -> Session {
        Session(accessToken: "access-token", tokenType: "bearer", expiresIn: 3600,
                expiresAt: Date().timeIntervalSince1970 + (expired ? -100 : 3600), refreshToken: "refresh-token",
                user: User(id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
                           email: "reader@example.com", createdAt: Date(), emailConfirmedAt: Date(), updatedAt: Date()))
    }

    private func client(storage: any AuthLocalStorage = MemoryAuthStorage(), session: Session? = nil,
                        fetch: @escaping AuthClient.FetchHandler = { _ in throw URLError(.notConnectedToInternet) }) throws -> AuthClient {
        if let session { try storage.store(key: "test-session", value: JSONEncoder().encode(session)) }
        return AuthClient(url: URL(string: "https://auth.example.com/auth/v1")!, headers: ["apikey": "public-test-key"],
                          storageKey: "test-session", localStorage: storage, fetch: fetch,
                          autoRefreshToken: false, emitLocalSessionAsInitialSession: true)
    }

    private func network(status: Int, body: String = "") -> URLSession {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            return (status, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func chat(auth: AIAuthController, network: URLSession = .shared) throws -> ChatController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ChatController(configStore: AIConfigStore(directory: directory), auth: auth, service: AIChatService(session: network))
    }

    private func settle(_ chat: ChatController) async throws {
        for _ in 0..<100 where chat.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(chat.isStreaming)
    }

    func testSignedOutSendKeepsDraftAndRequestsSignIn() throws {
        let auth = AIAuthController(client: nil)
        let chat = try chat(auth: auth)
        let reference = ChatReference(quotedText: "A passage", spineIndex: 0)
        chat.pendingReferences = [reference]
        chat.input = "Explain this passage"
        chat.send()
        XCTAssertTrue(auth.showingSignIn)
        XCTAssertEqual(chat.input, "Explain this passage")
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.pendingReferences, [reference])
    }

    func testVerifiedCodeCreatesSessionButDoesNotSendDraft() async throws {
        let wireSession = session()
        let sdk = try client { request in
            XCTAssertEqual(request.url?.lastPathComponent, "verify")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["token"] as? String, "123456")
            XCTAssertEqual(body["type"] as? String, "email")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return (try encoder.encode(wireSession), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let auth = AIAuthController(client: sdk)
        let chat = try chat(auth: auth)
        chat.input = "Keep my question"
        auth.showingSignIn = true
        try await auth.verifyCode("123456", email: "reader@example.com")
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.showingSignIn)
        XCTAssertEqual(chat.input, "Keep my question")
        XCTAssertTrue(chat.messages.isEmpty)
    }

    func testInvalidOrExpiredCodeDoesNotSignIn() async throws {
        let sdk = try client { request in
            (Data(#"{"msg":"Code expired","code":"otp_expired"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let auth = AIAuthController(client: sdk)
        do { try await auth.verifyCode("123456", email: "reader@example.com"); XCTFail("Should reject code") }
        catch { XCTAssertFalse(auth.isSignedIn) }
    }

    func testSendingCodeUsesSignupFlowAndDoesNotSignInBeforeVerification() async throws {
        let sdk = try client { request in
            XCTAssertEqual(request.url?.lastPathComponent, "otp")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["email"] as? String, "reader@example.com")
            XCTAssertEqual(body["create_user"] as? Bool, true)
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let auth = AIAuthController(client: sdk)
        try await auth.sendCode(to: "reader@example.com")
        XCTAssertFalse(auth.isSignedIn)
    }

    func testRestoresExistingSessionAndRefreshesExpiredToken() async throws {
        let storage = MemoryAuthStorage()
        let refreshed = session()
        let sdk = try client(storage: storage, session: session(expired: true)) { request in
            XCTAssertEqual(request.url?.lastPathComponent, "token")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return (try encoder.encode(refreshed), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let auth = AIAuthController(client: sdk)
        XCTAssertTrue(auth.isSignedIn)
        let token = try await auth.accessToken()
        XCTAssertEqual(token, refreshed.accessToken)
        let restored = AIAuthController(client: try client(storage: storage))
        XCTAssertEqual(restored.email, "reader@example.com")
    }

    func testRefreshNetworkFailureKeepsSessionAndDraft() async throws {
        let auth = AIAuthController(client: try client(session: session(expired: true)))
        let chat = try chat(auth: auth)
        chat.input = "Offline question"
        chat.send()
        try await settle(chat)
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.showingSignIn)
        XCTAssertEqual(chat.input, "Offline question")
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNotNil(chat.errorMessage)
    }

    func testServer401RestoresDraftWithoutReplaying() async throws {
        let auth = AIAuthController(client: try client(session: session()))
        let chat = try chat(auth: auth, network: network(status: 401))
        let reference = ChatReference(quotedText: "Keep this passage", spineIndex: 0)
        chat.pendingReferences = [reference]
        chat.input = "Question"
        chat.send()
        try await settle(chat)
        XCTAssertTrue(auth.showingSignIn)
        XCTAssertEqual(chat.input, "Question")
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.pendingReferences, [reference])
    }

    func testTemporaryServerFailureDoesNotSignOut() async throws {
        let auth = AIAuthController(client: try client(session: session()))
        let chat = try chat(auth: auth, network: network(status: 503))
        chat.input = "Question"
        chat.send()
        try await settle(chat)
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.showingSignIn)
        XCTAssertEqual(chat.input, "Question")
    }

    func testAuthenticatedStreamingReply() async throws {
        let auth = AIAuthController(client: try client(session: session()))
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"An answer\"}}]}\n\ndata: [DONE]\n\n"
        let chat = try chat(auth: auth, network: network(status: 200, body: body))
        chat.input = "Question"
        chat.send()
        try await settle(chat)
        XCTAssertEqual(chat.messages.last?.text, "An answer")
        XCTAssertNil(chat.errorMessage)
    }

    func testSignOutClearsLocalSessionEvenOfflineAndCallsCancellation() async throws {
        let storage = MemoryAuthStorage()
        let auth = AIAuthController(client: try client(storage: storage, session: session()))
        var cancelled = false
        auth.onWillSignOut = { cancelled = true }
        await auth.signOut()
        XCTAssertTrue(cancelled)
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(try storage.retrieve(key: "test-session"))
    }

    func testDeletionFailureKeepsAccountAndSuccessClearsIt() async throws {
        let auth = AIAuthController(client: try client(session: session()), network: network(status: 503))
        await auth.deleteAccount()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertNotNil(auth.accountError)
        let success = AIAuthController(client: try client(session: session()), network: network(status: 204))
        await success.deleteAccount()
        XCTAssertFalse(success.isSignedIn)
        XCTAssertNil(success.accountError)
    }

    func testExpiredRefreshTokenRequestsSignInAndKeepsDraft() async throws {
        let sdk = try client(session: session(expired: true)) { request in
            (Data(#"{"msg":"Refresh token not found","code":"refresh_token_not_found"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                             headerFields: ["X-Supabase-Api-Version": "2024-01-01"])!)
        }
        let auth = AIAuthController(client: sdk)
        let chat = try chat(auth: auth)
        chat.input = "Question to keep"
        chat.send()
        try await settle(chat)
        XCTAssertTrue(auth.showingSignIn)
        XCTAssertEqual(chat.input, "Question to keep")
        XCTAssertTrue(chat.messages.isEmpty)
    }

    func testEmailSendingFailureDoesNotCreateSession() async throws {
        for status in [429, 503] {
            let sdk = try client { request in
                (Data(#"{"msg":"Please try again later","code":"over_email_send_rate_limit"}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let auth = AIAuthController(client: sdk)
            do { try await auth.sendCode(to: "reader@example.com"); XCTFail("Should fail") }
            catch { XCTAssertFalse(auth.isSignedIn) }
        }
    }

    func testInterruptedPartialAnswerIsKeptAndNotReplayed() async throws {
        let auth = AIAuthController(client: try client(session: session()))
        var requests = 0
        let network = network(status: 200)
        MockURLProtocol.handler = { _ in
            requests += 1
            return (200, "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\ndata: {\"error\":{\"message\":\"Interrupted\"}}\n\n")
        }
        let chat = try chat(auth: auth, network: network)
        chat.input = "Question"
        chat.send()
        try await settle(chat)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(chat.messages.last?.text, "Partial answer")
        XCTAssertNotNil(chat.errorMessage)
    }

    func testKeychainSessionSurvivesNewClientAndIsRemovedOnSignOut() async throws {
        let service = "com.olly.KodiReader.auth.tests.\(UUID().uuidString)"
        let storage = KeychainLocalStorage(service: service)
        defer { try? storage.remove(key: "test-session") }
        let original = try client(storage: storage, session: session())
        XCTAssertNotNil(original.currentSession)
        let restored = AIAuthController(client: try client(storage: KeychainLocalStorage(service: service)))
        XCTAssertEqual(restored.email, "reader@example.com")
        await restored.signOut()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "test-session"]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
    }
}
