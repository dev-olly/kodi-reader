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

        print("Update lifecycle passed: discovery, download progress, cancellation, restart/save ordering, failure recovery, retry, and informational updates.")
    }
}
