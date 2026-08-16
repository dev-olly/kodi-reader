import AppKit
import ReaderUI
import SwiftUI

@main
struct EpubReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // Single `Window` (not WindowGroup): one reader surface, and closing
        // the traffic-light quits instead of leaving a Dock zombie.
        Window("Kodi Reader", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 480)
                // Opening a book from Finder or `open` arrives here, and the
                // grant that comes with it is what lets the sandbox read it.
                .onOpenURL { url in model.open(url: url) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 820)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flush() }
        }
        .commands { readerCommands }
    }

    @CommandsBuilder
    private var readerCommands: some Commands {
        // Keep the system New Item group; only append Open / Close Book.
        CommandGroup(after: .newItem) {
            Button("Open Book…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)

            Button("Close Book") { model.closeBook() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.book == nil)
        }

        CommandMenu("Go") {
            Button("Next Page") { model.reader?.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.isNoteEditorOpen)
            Button("Previous Page") { model.reader?.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.isNoteEditorOpen)
            Divider()
            Button("Next Chapter") { model.reader?.goToNextChapter() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model.isNoteEditorOpen)
            Button("Previous Chapter") { model.reader?.goToPreviousChapter() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model.isNoteEditorOpen)
        }

        CommandMenu("Read Aloud") {
            Button(model.readAloud.isPlaying ? "Pause" : "Play") {
                if model.readAloud.isActive {
                    model.readAloud.togglePause()
                } else {
                    model.toggleReadAloud()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.book == nil)

            Button("Stop") { model.readAloud.stop() }
            .disabled(!model.readAloud.isActive)

            Divider()

            Button("Skip Forward 15 Seconds") { model.readAloud.skipForward() }
            .keyboardShortcut(.rightArrow, modifiers: [.option])
            .disabled(!model.readAloud.isActive)

            Button("Skip Back 15 Seconds") { model.readAloud.skipBack() }
            .keyboardShortcut(.leftArrow, modifiers: [.option])
            .disabled(!model.readAloud.isActive)
        }

        CommandMenu("View") {
            Button("Table of Contents") { model.isShowingContents.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Notes & Highlights") { model.isShowingAnnotations.toggle() }
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
            Button("Larger Text") { model.settings.fontSize = min(32, model.settings.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { model.settings.fontSize = max(12, model.settings.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
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
