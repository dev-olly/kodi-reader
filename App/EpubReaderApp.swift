import ReaderUI
import SwiftUI

@main
struct EpubReaderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
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
        CommandGroup(replacing: .newItem) {
            Button("Open Book…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Close Book") { model.closeBook() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.book == nil)
        }

        CommandMenu("Go") {
            Button("Next Page") { model.reader?.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Page") { model.reader?.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            Button("Next Chapter") { model.reader?.goToNextChapter() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Chapter") { model.reader?.goToPreviousChapter() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }

        CommandMenu("View") {
            Button("Table of Contents") { model.isShowingContents.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Notes & Highlights") { model.isShowingAnnotations.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
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
