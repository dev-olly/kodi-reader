import AppKit
import ReaderUI
import SwiftUI

@main
struct KodiReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("kodiAuthWelcomeSeen") private var authWelcomeSeen = false
    @State private var model = AppModel()
    @StateObject private var updater = AppUpdater()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // Single `Window` (not WindowGroup): one reader surface, and closing
        // the traffic-light quits instead of leaving a Dock zombie.
        Window("Kodi Reader", id: "main") {
            RootView()
                .environment(model)
                .environmentObject(updater)
                .task { updater.beforeInstall = { model.flush() } }
                .frame(minWidth: 640, minHeight: 480)
                // Opening a book from Finder or `open` arrives here, and the
                // grant that comes with it is what lets the sandbox read it.
                .onOpenURL { url in
                    if url.scheme?.lowercased() != "com.olly.kodireader" {
                        model.open(url: url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 820)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flush() }
        }
        .commands { readerCommands }

        Settings {
            UpdateSettingsView(updater: updater)
        }
    }

    @CommandsBuilder
    private var readerCommands: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
        // Keep the system New Item group; append Open / Close commands.
        CommandGroup(after: .newItem) {
            Button("Open Document…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!authWelcomeSeen && !model.aiAuth.isSignedIn)

            Button("Open Webpage…") { model.presentOpenURL() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!authWelcomeSeen && !model.aiAuth.isSignedIn)

            Button("Save Webpage to Library") { model.saveCurrentWebPage() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.isBrowsing || model.isSavingWebPage)

            Divider()

            Button("Home") { model.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!model.canGoHome)

            Button(model.isBrowsing ? "Close Webpage" : "Close Document") {
                if model.isBrowsing { model.closeBrowser() } else { model.closeBook() }
            }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.canGoHome)
        }

        CommandMenu("Go") {
            Button("Home") { model.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!model.canGoHome)
            Divider()
            Button("Next Page") { model.reader?.nextPage() }
                .disabled(model.reader == nil)
            Button("Previous Page") { model.reader?.previousPage() }
                .disabled(model.reader == nil)
            Divider()
            Button(model.book?.kind == .pdf ? "Next Section" : "Next Chapter") {
                model.reader?.goToNextChapter()
            }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model.isNoteEditorOpen || model.reader?.canNavigateSections != true)
            Button(model.book?.kind == .pdf ? "Previous Section" : "Previous Chapter") {
                model.reader?.goToPreviousChapter()
            }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model.isNoteEditorOpen || model.reader?.canNavigateSections != true)
        }

        CommandMenu("View") {
            Button("Table of Contents") { model.isShowingContents.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Notes & Highlights") { model.toggleAnnotations() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Toggle(
                "Notes in Sidebar",
                isOn: Binding(
                    get: { model.notesInSidebar },
                    set: { model.notesInSidebar = $0 }
                )
            )
            Divider()
            Picker("Theme", selection: Binding(
                get: { model.settings.theme },
                set: { model.settings.theme = $0 }
            )) {
                ForEach(ReaderTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            Divider()
            Button(model.book?.kind == .pdf ? "Zoom In" : "Larger Text") {
                if model.book?.kind == .pdf {
                    model.reader?.zoomPDFIn()
                } else {
                    model.settings.fontSize = min(32, model.settings.fontSize + 1)
                }
            }
                .keyboardShortcut("+", modifiers: .command)
            Button(model.book?.kind == .pdf ? "Zoom Out" : "Smaller Text") {
                if model.book?.kind == .pdf {
                    model.reader?.zoomPDFOut()
                } else {
                    model.settings.fontSize = max(12, model.settings.fontSize - 1)
                }
            }
                .keyboardShortcut("-", modifiers: .command)
        }

        CommandMenu("Ask AI") {
            Button("Ask AI") { model.addSelectionToChat() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.book == nil)
            Button(model.isShowingAskAI ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleAskAI()
            }
            .disabled(model.book == nil)
        }
    }
}

/// Quits when the last window closes and opts out of AppKit window restoration
/// so we never resurrect the phantom AppWindow-N scenes from earlier launches.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Don't reopen previously restored windows on next launch.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        disableRestoration(on: NSApp.windows)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.disableRestoration(on: [window])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    private func disableRestoration(on windows: [NSWindow]) {
        for window in windows {
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("kodi-reader-main")
        }
    }
}
