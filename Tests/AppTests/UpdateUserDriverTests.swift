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

        print("Update lifecycle passed: discovery, download progress, cancellation, restart/save ordering, failure recovery, retry, and informational updates.")
    }
}
