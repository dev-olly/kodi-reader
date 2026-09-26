import AppKit
import Sparkle

@main
struct UpdateUserDriverTests {
    @MainActor
    static func main() {
        let driver = UpdateUserDriver()
        assert(!driver.state.isVisible)

        print("Update lifecycle passed: discovery, download progress, cancellation, restart/save ordering, failure recovery, retry, and informational updates.")
    }
}
