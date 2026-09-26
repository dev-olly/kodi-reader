import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle still owns scheduling, signature verification, installation, and relaunch.
/// The driver presents that lifecycle inside the reader instead of opening update windows.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var state = UpdateUserDriver.State()
    var beforeInstall: (() -> Void)?

    let driver = UpdateUserDriver()
    private var updater: SPUUpdater!

    override convenience init() { self.init(startingUpdater: true) }

    init(startingUpdater: Bool) {
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: driver, delegate: self)
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        driver.$state.assign(to: &$state)
        driver.beforeRestart = { [weak self] in self?.beforeInstall?() }
        guard startingUpdater else { return }
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            driver.state.message = "Updates are unavailable: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func performUpdateAction() {
        if state.phase == .failed {
            guard canCheckForUpdates else { return }
            driver.prepareToRetry()
            updater.checkForUpdates()
        } else {
            driver.performAction()
        }
    }

    func setAutomaticChecks(_ enabled: Bool) { updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { beforeInstall?() }
}

@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    enum Phase: Equatable { case idle, checking, available, downloading, preparing, ready, installing, failed }

    struct State: Equatable {
        var phase: Phase = .idle
        var version: String?
        var progress: Double?
        var message: String?
        var releaseNotes: String?
        var releaseNotesURL: URL?
        var informationURL: URL?

        var isVisible: Bool { version != nil && phase != .idle }
        var isBusy: Bool { [.checking, .downloading, .preparing].contains(phase) }
        var title: String {
            switch phase {
            case .idle, .available: return informationURL == nil ? "Update available" : "View update"
            case .checking: return "Checking…"
            case .downloading: return progress.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
            case .preparing: return "Preparing update…"
            case .ready, .installing: return "Restart to update"
            case .failed: return "Retry update"
            }
        }
    }

    @Published var state = State()
    var beforeRestart: (() -> Void)?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var retryTermination: (() -> Void)?
    private var cancel: (() -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var retryVersion: String?
    private var userInitiatedCheck = false

    func performAction() {
        if let url = state.informationURL {
            NSWorkspace.shared.open(url)
            return
        }
        if state.phase == .installing {
            guard let retryTermination else { return }
            beforeRestart?()
            retryTermination()
            return
        }
        guard let reply = choice, [.available, .ready].contains(state.phase) else { return }
        choice = nil
        state.message = nil
        if state.phase == .ready {
            beforeRestart?()
            state.phase = .installing
        } else {
            state.phase = .downloading
            state.progress = nil
        }
        reply(.install)
    }

    func prepareToRetry() {
        retryVersion = state.version
        state.phase = .checking
        state.message = nil
    }

    func cancelDownload() {
        let cancellation = cancel
        cancel = nil
        cancellation?()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist explicitly enables checks and disables profiling; this is a fallback.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiatedCheck = true
        state.phase = .checking
        state.message = nil
        cancel = cancellation
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        presentUpdate(version: appcastItem.displayVersionString,
                      ready: updateState.stage == .installing,
                      informationURL: appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil,
                      releaseNotes: appcastItem.itemDescription,
                      releaseNotesURL: appcastItem.releaseNotesURL, reply: reply)
    }

    // Kept separate so lifecycle tests can drive Sparkle's callbacks without network or installers.
    func presentUpdate(version: String, ready: Bool = false, informationURL: URL? = nil,
                       releaseNotes: String? = nil, releaseNotesURL: URL? = nil,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancel = nil
        choice = reply
        state = State(phase: ready ? .ready : .available, version: version,
                      releaseNotes: releaseNotes, releaseNotesURL: releaseNotesURL,
                      informationURL: informationURL)
        let shouldRetry = retryVersion == version && informationURL == nil && !ready
        retryVersion = nil
        if shouldRetry { performAction() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        state.releaseNotesURL = downloadData.url
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // The update remains installable; release notes are optional.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let shouldAlert = userInitiatedCheck
        userInitiatedCheck = false
        state = State(message: error.localizedDescription)
        retryVersion = nil
        acknowledgement()
        guard shouldAlert else { return }
        let alert = NSAlert()
        alert.messageText = "No update available"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let shouldAlert = userInitiatedCheck && state.version == nil
        userInitiatedCheck = false
        choice = nil
        cancel = nil
        retryTermination = nil
        retryVersion = nil
        state.progress = nil
        state.message = error.localizedDescription
        state.phase = state.version == nil ? .idle : .failed
        acknowledgement()
        if shouldAlert {
            let alert = NSAlert()
            alert.messageText = "Could not check for updates"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancel = cancellation
        expectedLength = 0
        receivedLength = 0
        state.phase = .downloading
        state.progress = nil
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        updateProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength = receivedLength.addingReportingOverflow(length).overflow
            ? UInt64.max : receivedLength + length
        updateProgress()
    }
    private func updateProgress() {
        state.progress = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil
    }
    func showDownloadDidStartExtractingUpdate() {
        cancel = nil
        state.phase = .preparing
        state.progress = nil
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        state.progress = min(1, max(0, progress))
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        state.phase = .ready
        state.progress = nil
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        state.phase = .installing
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state = State()
        acknowledgement()
    }
    func showUpdateInFocus() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissUpdateInstallation() {
        userInitiatedCheck = false
        retryVersion = nil
        choice = nil
        cancel = nil
        retryTermination = nil
        expectedLength = 0
        receivedLength = 0
        // Sparkle tears down the failed session after reporting an error. Keep its retry affordance.
        if state.phase != .failed { state = State(message: state.message) }
    }
}

struct UpdateButton: View {
    @EnvironmentObject private var updater: AppUpdater
    @State private var showingDetails = false

    var body: some View {
        if updater.state.isVisible {
            HStack(spacing: 0) {
                Button(action: updater.performUpdateAction) {
                    HStack(spacing: 6) {
                        if updater.state.isBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: updater.state.phase == .ready ? "arrow.clockwise" : "arrow.down.circle")
                        }
                        Text(updater.state.title)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(.tint)
                    .background(.tint.opacity(0.10), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(updater.state.isBusy || (updater.state.phase == .failed && !updater.canCheckForUpdates))
                .accessibilityLabel(updater.state.title)
                .accessibilityValue(updater.state.version ?? "")
            }
            .help(updater.state.message ?? "Kodi Reader \(updater.state.version ?? ""). Your reading progress is saved before restarting.")
            .contextMenu {
                Button("Update details…") { showingDetails = true }
                if updater.state.phase == .downloading {
                    Button("Cancel download", action: updater.driver.cancelDownload)
                }
            }
            .popover(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Kodi Reader \(updater.state.version ?? "")").font(.headline)
                    if let message = updater.state.message { Text(message).foregroundStyle(.secondary) }
                    if let url = updater.state.releaseNotesURL {
                        Link("What’s new", destination: url)
                    } else if let notes = updater.state.releaseNotes {
                        ScrollView { Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 260)
                    }
                    Text("Your books, notes, and reading progress are kept.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(width: 340)
            }
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            LabeledContent("Installed version", value: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "—")
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticChecks($0) }
            ))
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticDownloads($0) }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)
            Text("Kodi Reader checks on launch and daily. An update button appears when a new version is available. Your books, notes, and reading progress are kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
            UpdateButton().environmentObject(updater)
            if let message = updater.state.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Button(updater.state.phase == .checking ? "Checking…" : "Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Updates")
    }
}
