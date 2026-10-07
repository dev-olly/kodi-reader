import CryptoKit
import EpubKit
import Foundation
import Observation

/// Owns exactly one active cloud transport. The iCloud journal remains at its
/// original path; Drive journals are isolated by Google account ID.
@MainActor @Observable
final class LibrarySyncService {
    private struct Selection: Codable { var provider: SyncProvider; var accountID: String? }
    private struct LegacyJournal: Decodable { var preferences: SyncPreferences }
    private let store: LibraryStore
    private let root: URL
    private let selectionURL: URL
    private let cloud: CloudKitSyncTransport
    private let drive: GoogleDriveSyncTransport
    private let driveAuthorization: GoogleDriveAuthorization
    private var coordinator: LibrarySyncCoordinator
    private var selectedDriveAccountID: String?
    private var activePoll: Task<Void, Never>?
    private(set) var provider: SyncProvider
    private(set) var connectedAccount: String?
    var onLibraryChanged: (() -> Void)? { didSet { coordinator.onLibraryChanged = onLibraryChanged } }
    var isEditing: () -> Bool = { false } { didSet { coordinator.isEditing = isEditing } }
    var isEntityEditing: (SyncEntity) -> Bool = { _ in false } {
        didSet { coordinator.isEntityEditing = isEntityEditing }
    }

    var preferences: SyncPreferences { coordinator.preferences }
    var status: SyncStatus { coordinator.status }
    var googleConfigured: Bool { driveAuthorization.isConfigured }
    var googleConnected: Bool { driveAuthorization.isConnected }

    init(store: LibraryStore, iCloudEnabled: Bool, googleClientID: String?, googleClientSecret: String?) {
        self.store = store
        root = store.rootDirectory.appendingPathComponent("Sync", isDirectory: true)
        selectionURL = root.appendingPathComponent("selection.json")
        cloud = CloudKitSyncTransport(stagingDirectory: root.appendingPathComponent("Payloads"), enabled: iCloudEnabled)
        driveAuthorization = GoogleDriveAuthorization(clientID: googleClientID, clientSecret: googleClientSecret)
        drive = GoogleDriveSyncTransport(credentials: driveAuthorization,
                                         stagingDirectory: root.appendingPathComponent("DrivePayloads"))
        let selection = (try? Data(contentsOf: selectionURL)).flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        let selectedProvider: SyncProvider
        if let selection, selection.provider != .googleDrive || selection.accountID != nil {
            selectedProvider = selection.provider
        } else {
            let legacy = root.appendingPathComponent("journal.json")
            let saved = (try? Data(contentsOf: legacy)).flatMap { try? JSONDecoder().decode(LegacyJournal.self, from: $0) }
            selectedProvider = saved?.preferences.mode == .off || saved == nil ? .off : .iCloud
        }
        provider = selectedProvider
        selectedDriveAccountID = selection?.accountID
        let activeTransport: any SyncTransport = selectedProvider == .googleDrive ? drive : cloud
        let journal: URL? = selectedProvider == .googleDrive
            ? root.appendingPathComponent("GoogleDrive/\(Self.safeAccount(selection?.accountID))/journal.json") : nil
        coordinator = LibrarySyncCoordinator(store: store, transport: activeTransport,
            journalURL: journal, active: selectedProvider != .off)
    }

    func connectGoogleDrive() async throws {
        try await driveAuthorization.connect()
        let newAccount = try await drive.accountID()
        connectedAccount = drive.accountEmail
        if provider == .googleDrive, let old = selectedDriveAccountID, old != newAccount {
            coordinator.checkpoint()
            await coordinator.stop()
            provider = .off
            selectedDriveAccountID = nil
            try JSONEncoder().encode(Selection(provider: .off, accountID: nil)).write(to: selectionURL, options: .atomic)
            setActive(false)
        }
    }

    func disconnectGoogleDrive() async throws {
        if provider == .googleDrive {
            coordinator.checkpoint()
            await coordinator.stop()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Selection(provider: .off, accountID: nil)).write(to: selectionURL, options: .atomic)
            provider = .off
            selectedDriveAccountID = nil
            setActive(false)
        }
        driveAuthorization.disconnect()
        connectedAccount = nil
    }

    func copyPlan(mode: SyncMode) -> (books: Int, missing: Int, downloadable: Int) {
        let books = store.allBooks()
        let missing = books.filter { store.existingImportedURL(for: $0) == nil }
        return (books.count, mode == .booksAndNotes ? missing.count : 0,
                mode == .booksAndNotes ? missing.filter { $0.cloudFile != nil && preferences.mode == .booksAndNotes }.count : 0)
    }

    func prepareCopy() async throws {
        if provider != .off && !coordinator.status.requiresAcknowledgement {
            try await coordinator.prepareProviderSwitch()
        }
    }

    func downloadMissingForCopy() async throws {
        for book in store.allBooks() where store.existingImportedURL(for: book) == nil && book.cloudFile != nil {
            _ = try await coordinator.download(book)
        }
    }

    func selectProvider(_ next: SyncProvider, mode: SyncMode, syncAIHistory: Bool,
                        acknowledge: Bool = false) async throws {
        var changedGoogleAccount = false
        if next == provider {
            guard next != .off else { return }
            let currentAccount = next == .googleDrive ? try await drive.accountID() : nil
            if next != .googleDrive || currentAccount == selectedDriveAccountID {
                await coordinator.setPreferences(.init(mode: mode, syncAIHistory: syncAIHistory),
                                                 acknowledge: acknowledge)
                return
            }
            guard acknowledge else { throw SyncFailure.accountChanged }
            changedGoogleAccount = true
        }
        if next == .off {
            coordinator.checkpoint()
            await coordinator.stop()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Selection(provider: .off, accountID: nil)).write(to: selectionURL, options: .atomic)
            provider = .off; selectedDriveAccountID = nil; setActive(false)
            return
        }
        if next == .googleDrive && !driveAuthorization.isConnected { try await connectGoogleDrive() }
        if provider != .off && !changedGoogleAccount && !coordinator.status.requiresAcknowledgement {
            try await coordinator.prepareProviderSwitch()
        }
        if next != .off && mode == .booksAndNotes && copyPlan(mode: mode).missing > 0 {
            throw NSError(domain: "KodiSync", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Download or locate the missing books before copying Books and notes to another cloud."])
        }
        let accountID = next == .googleDrive ? try await drive.accountID() : nil
        coordinator.checkpoint()
        await coordinator.stop()
        let transport: any SyncTransport = next == .googleDrive ? drive : cloud
        let journal: URL? = next == .googleDrive
            ? root.appendingPathComponent("GoogleDrive/\(Self.safeAccount(accountID))/journal.json") : nil
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Selection(provider: next, accountID: accountID)).write(to: selectionURL, options: .atomic)
        let replacement = LibrarySyncCoordinator(store: store, transport: transport, journalURL: journal)
        replacement.onLibraryChanged = onLibraryChanged
        replacement.isEditing = isEditing
        replacement.isEntityEditing = isEntityEditing
        coordinator = replacement
        provider = next
        selectedDriveAccountID = accountID
        await coordinator.setPreferences(.init(mode: mode,
                                               syncAIHistory: syncAIHistory), acknowledge: acknowledge)
        if next == .googleDrive { connectedAccount = drive.accountEmail }
    }

    func setPreferences(_ value: SyncPreferences, acknowledge: Bool = false) async {
        guard provider != .off else { return }
        await coordinator.setPreferences(value, acknowledge: acknowledge)
    }
    func syncNow() {
        guard provider != .off else { return }
        coordinator.syncNow()
        if provider == .googleDrive && connectedAccount == nil {
            Task { [weak self] in
                guard let self, let account = try? await self.drive.accountID(),
                      account == self.selectedDriveAccountID else { return }
                self.connectedAccount = self.drive.accountEmail
            }
        }
    }
    func checkpoint() { coordinator.checkpoint() }
    func resumeDeferredChanges() { coordinator.resumeDeferredChanges() }
    func isLocalRecovery(_ id: String) -> Bool { coordinator.isLocalRecovery(id) }
    func download(_ book: BookRecord) async throws -> URL { try await coordinator.download(book) }
    func removeDownload(_ book: BookRecord) throws { try coordinator.removeDownload(book) }
    func deleteEverywhere(_ book: BookRecord) throws { try coordinator.deleteEverywhere(book) }

    func setActive(_ active: Bool) {
        activePoll?.cancel(); activePoll = nil
        guard active, provider == .googleDrive else { return }
        activePoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { break }
                self?.syncNow()
            }
        }
    }

    private static func safeAccount(_ account: String?) -> String {
        guard let account else { return "unconnected" }
        return SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
