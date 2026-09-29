import EpubKit
import SwiftUI

struct KodiSettingsView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var updater: AppUpdater
    @State private var selection = "icloud"
    @State private var pendingMode: SyncMode?

    var body: some View {
        TabView(selection: $selection) {
            iCloudSettings
                .tabItem { Label("iCloud", systemImage: "icloud") }.tag("icloud")
            UpdateSettingsView(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")
        }
        .frame(width: 510, height: 490)
        .confirmationDialog("Enable iCloud sync for this Mac?", isPresented: Binding(
            get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }
        ), titleVisibility: .visible) {
            Button(model.sync.status.requiresAcknowledgement ? "Upload This Mac’s Library to the Current iCloud Account" : "Enable iCloud Sync") {
                guard let mode = pendingMode else { return }
                pendingMode = nil
                Task { await model.sync.setPreferences(.init(mode: mode, syncAIHistory: model.sync.preferences.syncAIHistory), acknowledge: model.sync.status.requiresAcknowledgement) }
            }
        } message: {
            Text("Your selected reading data will use your personal iCloud storage. Notes only is recommended to start. Turning sync off later keeps existing cloud copies.")
        }
    }

    private var iCloudSettings: some View {
        Form {
            Section {
                Picker("iCloud Sync", selection: Binding(
                    get: { model.sync.preferences.mode },
                    set: { mode in
                        if mode != .off && (model.sync.preferences.mode == .off || model.sync.status.requiresAcknowledgement) {
                            pendingMode = mode
                        } else { Task { await model.sync.setPreferences(.init(mode: mode, syncAIHistory: model.sync.preferences.syncAIHistory)) } }
                    }
                )) {
                    ForEach(SyncMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Notes only syncs notes, highlights, drawings, bookmarks, and reading position. Open the same book on each Mac to use them.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Books and notes also syncs EPUBs, PDFs, and saved webpages. Books download when opened; use Download for Offline Reading to prepare ahead.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Sync Ask AI history", isOn: Binding(
                    get: { model.sync.preferences.syncAIHistory },
                    set: { enabled in Task { await model.sync.setPreferences(.init(mode: model.sync.preferences.mode, syncAIHistory: enabled)) } }
                ))
                .disabled(model.sync.preferences.mode == .off)
                Text("Saved conversations and passage references only. Your sign-in, credits, and unsent drafts stay separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status", value: model.sync.status.phase.rawValue)
                if let last = model.sync.status.lastSuccessfulSync {
                    LabeledContent("Last synced") { Text(last, style: .relative) }
                }
                if let message = model.sync.status.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Sync Now") { model.sync.syncNow() }
                    .disabled(model.sync.preferences.mode == .off || model.sync.status.phase == .syncing)
                Button("Show Books Hidden from Recent") { model.showHiddenBooks() }
            }
            Text("Uses the iCloud account signed into this Mac. These choices apply only to this Mac. Reading and editing remain available offline.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
