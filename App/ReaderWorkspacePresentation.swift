import Foundation
import Observation

/// Show the workspace before waiting for WebKit, then allow its captured layout
/// to resize the page. A pending capture keeps the panel over the unchanged book.
@MainActor
@Observable
final class ReaderWorkspacePresentation {
    enum Workspace: String { case closed, notes, reminders, askAI }
    private(set) var visible: Workspace = .closed
    private(set) var isPreparingLayout = false
    @ObservationIgnored private var requested: Workspace = .closed
    @ObservationIgnored private var transition = 0
    @ObservationIgnored private var captureID: UUID?

    func request(_ workspace: Workspace,
                 prepareLayout: @escaping (@escaping () -> Void) -> Void,
                 releaseLayout: @escaping (@escaping () -> Void) -> Void,
                 flushNotes: @escaping (@escaping (Bool) -> Void) -> Void) {
        let previousRequest = requested
        // Repeated clicks must not invalidate a capture that is already running.
        guard workspace != visible || workspace != previousRequest else { return }
        requested = workspace
        transition += 1
        let token = transition
        let commit = { [weak self] in
            guard let self, self.transition == token else { return }
            self.visible = workspace
            if workspace == .closed {
                self.captureID = nil
                self.isPreparingLayout = false
            }
        }
        let navigate = { [weak self] in
            guard let self, self.transition == token else { return }
            if workspace == .closed {
                self.captureID = nil
                releaseLayout(commit)
            } else if self.visible == .closed || previousRequest == .closed {
                let id = UUID()
                self.captureID = id
                self.isPreparingLayout = true
                self.visible = workspace
                prepareLayout { [weak self] in
                    guard let self, self.captureID == id else { return }
                    self.captureID = nil
                    self.isPreparingLayout = false
                }
            } else {
                commit()
            }
        }
        if visible == .notes, workspace != .notes {
            flushNotes { [weak self] succeeded in
                guard let self, self.transition == token else { return }
                if succeeded { navigate() }
                else { self.requested = self.visible }
            }
        } else {
            navigate()
        }
    }
}
