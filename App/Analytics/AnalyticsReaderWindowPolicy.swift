import AppKit
import SwiftUI

/// Personal reading goals require the main reader window itself to be key.
/// Product engagement also includes a reader-owned note/drawing sheet and its
/// temporary tools, without allowing unrelated sheets or app windows.
enum AnalyticsReaderWindowPolicy {
    enum KeyContext { case reader, editor, transient, unrelated, none }

    static func isEngaged(readerVisible: Bool, readerMinimized: Bool,
                          appActive: Bool, keyContext: KeyContext) -> Bool {
        guard readerVisible, !readerMinimized, appActive else { return false }
        switch keyContext {
        case .reader, .editor, .transient: return true
        case .unrelated, .none: return false
        }
    }
}

/// Place only in NoteEditor. A sheet's parent alone cannot establish ownership:
/// authentication, payments, rename, and reminder sheets share that same parent.
@MainActor
struct AnalyticsReaderEditorMarker: NSViewRepresentable {
    static let windowsChanged = Notification.Name("KodiAnalyticsEditorWindowsChanged")

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.post(name: AnalyticsReaderEditorMarker.windowsChanged, object: nil)
        }
    }

    static func isPresent(in window: NSWindow) -> Bool {
        func containsMarker(_ view: NSView) -> Bool {
            guard !view.isHidden else { return false }
            return view is MarkerView || view.subviews.contains(where: containsMarker)
        }
        return window.contentView.map(containsMarker) ?? false
    }
}
