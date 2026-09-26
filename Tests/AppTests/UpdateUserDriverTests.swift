import AppKit
import Sparkle

@main
struct UpdateUserDriverTests {
    @MainActor
    static func main() {
        let driver = UpdateUserDriver()
        assert(!driver.state.isVisible)

        var quietErrorAcknowledged = false
        driver.showUpdaterError(NSError(domain: "Offline background check", code: 1)) { quietErrorAcknowledged = true }
        assert(quietErrorAcknowledged && !driver.state.isVisible, "Background failures must stay quiet")
        driver.dismissUpdateInstallation()

        var choices: [SPUUserUpdateChoice] = []
        driver.presentUpdate(version: "0.4.0", releaseNotes: "A quieter update experience.") {
            choices.append($0)
        }
        assert(driver.state.isVisible && driver.state.title == "Update available")
        assert(choices.isEmpty, "Discovering an update must not install it")
        driver.performAction()
        driver.performAction()
        assert(choices == [.install], "Repeated clicks must not reply twice")

        var cancelled = false
        driver.showDownloadInitiated { cancelled = true }
        driver.showDownloadDidReceiveData(ofLength: 25)
        assert(driver.state.progress == nil, "Unknown download sizes must be indeterminate")
        driver.showDownloadDidReceiveExpectedContentLength(100)
        assert(driver.state.progress == 0.25)
        driver.showDownloadDidReceiveData(ofLength: 200)
        assert(driver.state.progress == 1, "Incorrect content lengths must not exceed 100%")
        driver.showDownloadDidReceiveExpectedContentLength(300)
        assert(driver.state.progress == 0.75, "A revised size must retain received bytes")
        driver.showDownloadDidStartExtractingUpdate()
        driver.cancelDownload()
        assert(!cancelled, "Do not invoke download cancellation during extraction")

        var restartEvents: [String] = []
        driver.beforeRestart = { restartEvents.append("save") }
        driver.showReady(toInstallAndRelaunch: { choice in
            assert(choice == .install)
            restartEvents.append("install")
        })
        assert(driver.state.title == "Restart to update" && restartEvents.isEmpty)
        driver.performAction()
        driver.performAction()
        assert(restartEvents == ["save", "install"], "Save before requesting restart, exactly once")
        driver.showInstallingUpdate(withApplicationTerminated: false) { restartEvents.append("retry termination") }
        driver.performAction()
        assert(restartEvents.suffix(2) == ["save", "retry termination"])

        var acknowledged = false
        driver.showUpdaterError(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"])) {
            acknowledged = true
        }
        driver.dismissUpdateInstallation()
        assert(acknowledged && driver.state.phase == .failed && driver.state.isVisible)
        assert(driver.state.message == "Offline", "Retain the failure after Sparkle tears down the session")
        driver.prepareToRetry()
        driver.presentUpdate(version: "0.4.0") { choices.append($0) }
        assert(choices == [.install, .install], "Retry must resume the same version without a second click")

        driver.showUpdaterError(NSError(domain: "Test", code: 2)) {}
        driver.prepareToRetry()
        driver.presentUpdate(version: "0.5.0") { choices.append($0) }
        assert(driver.state.phase == .available && choices.count == 2,
               "A newly discovered version must wait for the user's click")
        driver.dismissUpdateInstallation()
        driver.performAction()
        assert(!driver.state.isVisible && choices.count == 2, "Dismissal clears pending install callbacks")

        driver.presentUpdate(version: "0.5.0", informationURL: URL(string: "https://example.com/update")!) {
            choices.append($0)
        }
        assert(driver.state.title == "View update", "Informational updates must not offer installation")
        driver.dismissUpdateInstallation()

        driver.presentUpdate(version: "0.4.0") { _ in }
        driver.showDownloadInitiated { cancelled = true }
        driver.cancelDownload()
        assert(cancelled)
        driver.dismissUpdateInstallation()
        assert(!driver.state.isVisible)

        print("Update lifecycle passed: discovery, download progress, cancellation, restart/save ordering, failure recovery, retry, and informational updates.")
    }
}
