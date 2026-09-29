import Foundation
import Observation

struct AICreditPack: Decodable, Identifiable {
    let id: String
    let name: String
    let credits: Int
    let amount: Int?
    let available: Bool
    var formattedPrice: String? { amount.map { (Double($0) / 100).formatted(.currency(code: "EUR")) } }
}

@MainActor @Observable
final class AICreditsController {
    private(set) var balance: Int?
    private(set) var enforced = false
    private(set) var packs: [AICreditPack] = []
    private(set) var sandbox = false
    private(set) var busy = false
    private(set) var addedCredits: Int?
    private(set) var confirmingPurchase = false
    private struct PendingPurchase: Codable {
        let id: UUID
        let user: UUID
        let pack: String
    }
    @ObservationIgnored private var pendingPurchase: PendingPurchase?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var monitorID = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let automaticallyMonitorPurchases: Bool
    @ObservationIgnored private let paymentsEnabled: Bool
    var error: String?
    var showingPacks = false
    @ObservationIgnored private let auth: AIAuthController
    @ObservationIgnored private let network: URLSession
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var checkoutIDs: [String: UUID] = [:]
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var refreshID = UUID()

    init(auth: AIAuthController, network: URLSession = .shared,
         baseURL: URL = URL(string: AIModelConfig.kodiHosted.baseURL)!,
         defaults: UserDefaults = .standard, automaticallyMonitorPurchases: Bool = true,
         paymentsEnabled: Bool = AIFeatureFlags.paymentsEnabled) {
        self.auth = auth; self.network = network; self.baseURL = baseURL
        self.defaults = defaults; self.automaticallyMonitorPurchases = automaticallyMonitorPurchases
        self.paymentsEnabled = paymentsEnabled
    }
    deinit { monitor?.cancel() }
    func reset() {
        monitor?.cancel(); monitor = nil; monitorID = UUID()
        pendingPurchase = nil; addedCredits = nil; confirmingPurchase = false
        revision = UUID(); owner = nil; balance = nil; packs = []; enforced = false
        error = nil; showingPacks = false; busy = false; checkoutIDs = [:]
    }
    func refresh() async {
        guard paymentsEnabled else { reset(); return }
        let user = auth.userID
        if owner != user { reset(); owner = user }
        guard let user else { return }
        let revision = revision
        let refresh = UUID(); refreshID = refresh
        do {
            let token = try await auth.accessToken()
            async let balanceData = request("credits", token: token)
            async let packsData = request("credit-packs", token: token)
            let (a,b) = try await (balanceData,packsData)
            struct Balance: Decodable { let balance: Int?; let enforced: Bool }
            struct Catalog: Decodable { let packs: [AICreditPack]; let sandbox: Bool }
            let result = try JSONDecoder().decode(Balance.self, from: a)
            let catalog = try JSONDecoder().decode(Catalog.self, from: b)
            guard auth.userID == user, self.revision == revision, refreshID == refresh else { return }
            balance = result.balance; enforced = result.enforced; packs = catalog.packs
            sandbox = catalog.sandbox; error = nil
        } catch {
            guard auth.userID == user, self.revision == revision, refreshID == refresh else { return }
            if case AIChatError.authRequired = error { auth.showingSignIn = true }
            self.error = error.localizedDescription
        }
        if auth.userID == user, self.revision == revision {
            restorePurchase(for: user)
            startMonitoring()
        }
    }
    func checkout(pack: AICreditPack) async -> URL? {
        guard paymentsEnabled, !busy, pack.available, let user = auth.userID, owner == user else { return nil }
        let revision = revision
        busy = true; error = nil
        defer { if self.revision == revision { busy = false } }
        do {
            let token = try await auth.accessToken()
            guard auth.userID == user, self.revision == revision else { return nil }
            let id = checkoutIDs[pack.id] ?? UUID()
            checkoutIDs[pack.id] = id
            let data = try await request("checkout", token: token, pack: pack.id, id: id)
            struct Checkout: Decodable { let url: URL }
            let checkout = try JSONDecoder().decode(Checkout.self, from: data)
            guard auth.userID == user, self.revision == revision, checkout.url.scheme == "https" else { return nil }
            pendingPurchase = PendingPurchase(id: id, user: user, pack: pack.id)
            defaults.set(try JSONEncoder().encode(pendingPurchase!), forKey: purchaseKey(user))
            addedCredits = nil; confirmingPurchase = true
            startMonitoring()
            return checkout.url
        } catch {
            if auth.userID == user, self.revision == revision {
                if case AIChatError.http(409, let message) = error, message.contains("purchase is complete") { checkoutIDs[pack.id] = nil }
                self.error = error.localizedDescription
            }
            return nil
        }
    }
    private func purchaseKey(_ user: UUID) -> String { "kodi.pendingPurchase.\(user.uuidString)" }
    private func restorePurchase(for user: UUID) {
        guard pendingPurchase == nil,
              let data = defaults.data(forKey: purchaseKey(user)),
              let pending = try? JSONDecoder().decode(PendingPurchase.self, from: data), pending.user == user else { return }
        pendingPurchase = pending
        checkoutIDs[pending.pack] = pending.id
    }
    @discardableResult
    func handlePaymentReturn(_ url: URL) -> Bool {
        guard paymentsEnabled else { return false }
        #if KODI_PAYMENT_SANDBOX
        let scheme = "com.olly.kodireader.sandbox"
        #else
        let scheme = "com.olly.kodireader"
        #endif
        guard url.scheme?.lowercased() == scheme, url.host == "credits", url.path == "/complete",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "order" })?.value,
              let id = UUID(uuidString: raw), let user = auth.userID else { return false }
        restorePurchase(for: user)
        guard pendingPurchase?.id == id, pendingPurchase?.user == user else { return false }
        confirmingPurchase = true; showingPacks = true
        startMonitoring()
        return true
    }
    private func startMonitoring() {
        guard paymentsEnabled, automaticallyMonitorPurchases, pendingPurchase != nil, monitor == nil else { return }
        let generation = UUID(); monitorID = generation
        confirmingPurchase = true
        monitor = Task { [weak self] in
            // Bounded polling also works if the browser blocks the app redirect.
            for attempt in 0..<36 {
                guard !Task.isCancelled, self?.monitorID == generation else { return }
                await self?.checkPendingPurchase()
                guard self?.pendingPurchase != nil, !Task.isCancelled else { break }
                do { try await Task.sleep(for: .seconds(attempt < 12 ? 2 : attempt < 24 ? 5 : 10)) }
                catch { return }
            }
            guard let self, self.monitorID == generation else { return }
            self.monitor = nil; self.confirmingPurchase = false
            if self.pendingPurchase != nil {
                self.error = "Payment confirmation is taking longer. You can keep reading; we’ll check again when you return to the app."
            }
        }
    }
    func checkPendingPurchase() async {
        guard paymentsEnabled, let pending = pendingPurchase, auth.userID == pending.user else { return }
        let revision = revision
        do {
            let token = try await auth.accessToken()
            let data = try await request("checkout/\(pending.id.uuidString.lowercased())", token: token)
            struct Status: Decodable { let id: UUID; let status: String; let credits: Int; let balance: Int }
            let result = try JSONDecoder().decode(Status.self, from: data)
            guard !Task.isCancelled, self.revision == revision, auth.userID == pending.user,
                  pendingPurchase?.id == pending.id, result.id == pending.id else { return }
            refreshID = UUID() // Ignore older balance refreshes still in flight.
            balance = result.balance
            if result.status == "confirmed", result.credits > 0 {
                pendingPurchase = nil
                defaults.removeObject(forKey: purchaseKey(pending.user))
                checkoutIDs[pending.pack] = nil
                error = nil; confirmingPurchase = false
                addedCredits = result.credits; showingPacks = true
            } else if result.status == "review" {
                pendingPurchase = nil
                defaults.removeObject(forKey: purchaseKey(pending.user))
                confirmingPurchase = false
                error = "This payment needs review or has been refunded. Contact olly@kodi-reader.app for help."
            }
        } catch {
            guard !Task.isCancelled, self.revision == revision, auth.userID == pending.user else { return }
            // Keep the purchase to retry after a network failure or app relaunch.
            if case AIChatError.authRequired = error { auth.showingSignIn = true }
        }
    }
    func dismissPurchaseSuccess() { addedCredits = nil; showingPacks = false }
    private func request(_ path: String, token: String, pack: String? = nil, id: UUID? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let pack {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(id?.uuidString, forHTTPHeaderField: "Idempotency-Key")
            request.httpBody = try JSONEncoder().encode(["pack": pack])
        }
        let (data,response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw AIChatError.authRequired }
        guard (200...299).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            throw AIChatError.http(http.statusCode, message ?? "Credits are temporarily unavailable. Please try again.")
        }
        return data
    }
}
