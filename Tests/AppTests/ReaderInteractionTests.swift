import AppKit
import EpubKit
import ReaderUI
import SwiftUI

@main struct ReaderInteractionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        testImmediateWorkspacePresentation()
        testWorkspaceRacesAndSaveFailures()
        testPaletteClicks()
    }

    @MainActor private static func testImmediateWorkspacePresentation() {
        let state = ReaderWorkspacePresentation()
        var captures: [() -> Void] = []
        var releases: [() -> Void] = []
        var saves = 0
        let prepare: (@escaping () -> Void) -> Void = { captures.append($0) }
        let release: (@escaping () -> Void) -> Void = { releases.append($0) }
        let flush: (@escaping (Bool) -> Void) -> Void = { saves += 1; $0(true) }
        state.request(.notes, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        assert(state.visible == .notes && state.isPreparingLayout,
               "The first click must show Notes synchronously, even while WebKit is delayed")
        assert(saves == 0 && captures.count == 1)
        for _ in 0..<5 {
            state.request(.notes, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        }
        assert(captures.count == 1, "Repeated clicks must not restart or cancel the first capture")
        state.request(.reminders, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        assert(state.visible == .reminders && state.isPreparingLayout && saves == 1)
        captures[0]()
        assert(state.visible == .reminders && !state.isPreparingLayout,
               "Changing tabs must not orphan a pending page-layout capture")
        state.request(.closed, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        assert(releases.count == 1)
        releases[0]()
        assert(state.visible == .closed && !state.isPreparingLayout)
        print("Workspace: first-click presentation precedes WebKit, duplicate clicks are stable, and tab changes preserve the capture")
    }

    @MainActor private static func testWorkspaceRacesAndSaveFailures() {
        let state = ReaderWorkspacePresentation()
        var captures: [() -> Void] = []
        var releases: [() -> Void] = []
        var saves: [(Bool) -> Void] = []
        let prepare: (@escaping () -> Void) -> Void = { captures.append($0) }
        let release: (@escaping () -> Void) -> Void = { releases.append($0) }
        let flush: (@escaping (Bool) -> Void) -> Void = { saves.append($0) }
        state.request(.notes, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        state.request(.closed, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        assert(state.visible == .notes && releases.isEmpty, "An active note must be saved before closing")
        saves.removeFirst()(true)
        assert(releases.count == 1)
        state.request(.notes, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        assert(captures.count == 2 && state.isPreparingLayout)
        captures[0]()
        releases[0]()
        assert(state.visible == .notes && state.isPreparingLayout, "Stale close/capture callbacks cannot hide a reopened editor")
        captures[1]()
        assert(!state.isPreparingLayout)
        state.request(.askAI, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        saves.removeFirst()(false)
        assert(state.visible == .notes, "A failed save keeps the current editor visible")
        state.request(.askAI, prepareLayout: prepare, releaseLayout: release, flushNotes: flush)
        assert(saves.count == 1, "The same action must be retryable after a save failure")
        saves.removeFirst()(true)
        assert(state.visible == .askAI)
        print("Workspace: close/reopen races, stale callbacks, and failed-save retry passed")
    }

    @MainActor private static func testPaletteClicks() {
        var notes = 0
        let palette = HighlightPalette(onPick: { _ in }, onAddNote: { notes += 1 }, onAskAI: {},
            onCopy: {}, onDismiss: {}, currentColor: .purple, hasNote: true, hasAttachedContent: true,
            onDelete: {}, onAddReminder: {})
        let host = NSHostingView(rootView: palette.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = NSRect(x: 0, y: 0, width: 1300, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        defer { window.contentView = nil; window.orderOut(nil) }
        settle(host)
        settle(host)
        let nativeViews = [host] + descendants(host)
        // SwiftUI's accessibility projection is lazy without an external AX
        // client. Native focus rectangles still give the actual button bounds.
        var targets: [(view: NSView, frame: NSRect)] = []
        for view in nativeViews where abs(view.bounds.height - 32) < 0.1 && view.bounds.width > 0 && view.bounds.width < 180 {
            let frame = view.convert(view.bounds, to: nil)
            if !targets.contains(where: { $0.frame == frame }) { targets.append((view, frame)) }
        }
        targets.sort { $0.frame.minX < $1.frame.minX }
        assert(targets.count > HighlightColor.allCases.count)
        let note = targets[HighlightColor.allCases.count].view
        let frame = note.convert(note.bounds, to: nil)
        assert(frame.height >= 32, "The full 32-point Note label must be clickable")
        window.resignKey()
        var clicks = 0
        for x in [CGFloat(0.15), 0.5, 0.85] {
            for y in [CGFloat(0.1), 0.5, 0.9] {
                let point = NSPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
                let before = notes
                let down = mouse(.leftMouseDown, at: point, window: window)
                let up = mouse(.leftMouseUp, at: point, window: window)
                window.sendEvent(down)
                window.sendEvent(up)
                settle(host)
                assert(notes == before + 1, "A single click anywhere in the Note label must trigger exactly one action")
                clicks += 1
            }
        }
        assert(notes == clicks)
        assert(note.convert(note.bounds, to: nil) == frame, "Clicking the palette must not churn its native bounds")
        print("Highlight palette: \(clicks) single clicks across the label, icon gap, and vertical padding all activated Notes")
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }

    @MainActor private static func settle(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
