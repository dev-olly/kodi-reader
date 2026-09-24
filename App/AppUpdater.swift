import Combine
import Sparkle
import SwiftUI

/// One updater for the whole app. Sparkle owns downloading, verification,
/// installation, and relaunch; reading data stays in Application Support.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false
    var beforeInstall: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beforeInstall?()
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
            Text("Kodi Reader checks daily and lets you know when an update is available. Your books, notes, and reading progress are kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Updates")
    }
}
