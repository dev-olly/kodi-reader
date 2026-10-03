import EpubKit
import SwiftUI

struct KodiSettingsView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var updater: AppUpdater
    @State private var selection = "sync"
    @State private var pendingProvider: SyncProvider?
    @State private var pendingMode: SyncMode = .notesOnly
    @State private var errorMessage: String?

    var body: some View {
        TabView(selection: $selection) {
            syncSettings
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag("sync")
            UpdateSettingsView(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
        }
        .frame(width: 540, height: 540)
        .confirmationDialog("Copy this Mac’s library to \(pendingProvider?.title ?? "cloud")?",
                            isPresented: Binding(get: { pendingProvider != nil }, set: { if !$0 { pendingProvider = nil } }),
                            titleVisibility: .visible) {
            if pendingMode == .booksAndNotes && model.sync.copyPlan(mode: pendingMode).missing > 0 {
                if model.sync.copyPlan(mode: pendingMode).downloadable > 0 {
                    Button("Download Missing Books First") { downloadMissing() }
                }
                Button("Use Notes only Instead") { confirm(mode: .notesOnly) }
            } else {
                Button("Copy and Enable Sync") { confirm(mode: pendingMode) }
            }
        } message: {
            let plan = model.sync.copyPlan(mode: pendingMode)
            Text("\(plan.books) books are in this Mac’s library. \(pendingMode.title) and \(model.sync.preferences.syncAIHistory ? "saved Ask AI history" : "no Ask AI history") will copy. \(plan.missing > 0 ? "\(plan.missing) book files need to be downloaded or located first. " : "")The previous cloud copy stays untouched. Only one provider syncs at a time.")
        }
        .alert("Sync needs attention", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var syncSettings: some View {
        Form {
            Section("Cloud provider") {
                Picker("Provider", selection: Binding(
                    get: { model.sync.provider },
                    set: { provider in
                        if provider == .off {
                            Task {
                                do {
                                    try await model.sync.selectProvider(.off, mode: .off,
                                        syncAIHistory: model.sync.preferences.syncAIHistory)
                                } catch { errorMessage = error.localizedDescription }
                            }
                        } else if provider != model.sync.provider || model.sync.status.requiresAcknowledgement {
                            Task {
                                do {
                                    try await model.sync.prepareCopy()
                                    pendingMode = model.sync.preferences.mode == .off ? .notesOnly : model.sync.preferences.mode
                                    pendingProvider = provider
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }
                    }
                )) {
                    ForEach(SyncProvider.allCases) { Text($0.title).tag($0) }
                }
                if model.sync.provider == .googleDrive {
                    LabeledContent("Account", value: model.sync.connectedAccount ?? "Connected Google Drive")
                }
                Button(model.sync.googleConnected ? "Change Google Account…" : "Connect Google Drive…") {
                    Task {
                        do { try await model.sync.connectGoogleDrive() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(!model.sync.googleConfigured)
                if model.sync.googleConnected {
                    Button("Disconnect Google Drive") {
                        Task {
                            do { try await model.sync.disconnectGoogleDrive() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                if !model.sync.googleConfigured {
                    Text("Google Drive is not configured in this build.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Google Drive uses hidden app data in your Google account. It uses your Google storage and requires separate permission from Ask AI sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What to sync") {
                Picker("Content", selection: Binding(
                    get: { model.sync.preferences.mode == .off ? .notesOnly : model.sync.preferences.mode },
                    set: { mode in
                        Task { await model.sync.setPreferences(.init(mode: mode, syncAIHistory: model.sync.preferences.syncAIHistory)) }
                    }
                )) {
                    Text("Notes only").tag(SyncMode.notesOnly)
                    Text("Books and notes").tag(SyncMode.booksAndNotes)
                }
                .disabled(model.sync.provider == .off)
                Text("Notes only includes highlights, notes, drawings, bookmarks, reading position, and book details. Locate the matching book on each Mac. Books and notes also transfers EPUBs, PDFs, and saved webpages on demand.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Sync Ask AI history", isOn: Binding(
                    get: { model.sync.preferences.syncAIHistory },
                    set: { enabled in Task { await model.sync.setPreferences(.init(mode: model.sync.preferences.mode, syncAIHistory: enabled)) } }
                ))
                .disabled(model.sync.provider == .off)
                Text("Saved conversations and passage references only. Sign-in, credits, and unsent drafts stay local.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("State", value: model.sync.provider == .off ? "Off" : model.sync.status.phase.rawValue)
                if let last = model.sync.status.lastSuccessfulSync {
                    LabeledContent("Last synced") { Text(last, style: .relative) }
                }
                if let message = model.sync.status.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if model.sync.status.requiresAcknowledgement && model.sync.provider != .off {
                    Button("Review and Re-enable Sync…") {
                        pendingMode = model.sync.preferences.mode == .off ? .notesOnly : model.sync.preferences.mode
                        pendingProvider = model.sync.provider
                    }
                }
                Button("Sync Now") { model.sync.syncNow() }
                    .disabled(model.sync.provider == .off || model.sync.status.phase == .syncing)
                Button("Show Books Hidden from Recent") { model.showHiddenBooks() }
            }
            Text("These choices apply only to this Mac. Reading and editing remain available offline. Google Drive checks for changes every five minutes while Kodi is active.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func confirm(mode: SyncMode) {
        guard let provider = pendingProvider else { return }
        pendingProvider = nil
        Task {
            do {
                try await model.sync.selectProvider(provider, mode: mode,
                    syncAIHistory: model.sync.preferences.syncAIHistory,
                    acknowledge: model.sync.status.requiresAcknowledgement)
                model.sync.setActive(true)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func downloadMissing() {
        let provider = pendingProvider
        pendingProvider = nil
        Task {
            do {
                try await model.sync.downloadMissingForCopy()
                pendingProvider = provider
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
