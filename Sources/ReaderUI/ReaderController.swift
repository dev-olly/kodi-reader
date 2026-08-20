import EpubKit
import Foundation
import Observation
import WebKit

#if os(macOS)
import AppKit
#endif

/// A live text selection, positioned so the app can anchor a popover to it.
public struct ReaderSelection: Equatable, Sendable {
    public var text: String
    public var locator: Locator
    /// Viewport coordinates of the selection's last rect.
    public var rect: CGRect
}

/// A speakable span extracted from the current spine document.
public struct ReaderUtterance: Equatable, Sendable {
    public var text: String
    public var start: TextPosition
    public var end: TextPosition

    public var locator: Locator {
        Locator(spineIndex: 0, start: start, end: end, text: text)
    }
}

/// Drives the web view: loads spine documents, moves between pages and
/// chapters, tracks position, and relays selections and highlights.
@Observable
public final class ReaderController {
    // MARK: - Observable state

    public private(set) var book: EPUBBook?
    public private(set) var spineIndex: Int = 0
    public private(set) var page: Int = 0
    public private(set) var pageCount: Int = 1
    public private(set) var chapterTitle: String?
    /// Progress through the whole book, 0 to 1.
    public private(set) var progress: Double = 0
    public private(set) var isLoading: Bool = false
    public private(set) var selection: ReaderSelection?
    public private(set) var annotations: [Annotation] = []
    public private(set) var errorMessage: String?

    public var settings: ReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            onSettingsChanged?(settings)
            if settings.affectsPageLayout(relativeTo: oldValue) {
                applySettings()
            }
        }
    }

    // MARK: - Callbacks

    /// Fires as the reader moves, so the app can persist the position.
    public var onPositionChanged: ((Locator) -> Void)?
    public var onSettingsChanged: ((ReaderSettings) -> Void)?
    /// Fires when a highlight is clicked, with viewport coordinates.
    public var onHighlightActivated: ((UUID, CGRect) -> Void)?
    /// Fires after highlights are painted, with resolve/repair/orphan results.
    public var onAnchorsResolved: (([AnchorResolution]) -> Void)?

    // MARK: - Private

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var schemeHandler: EPUBSchemeHandler?
    @ObservationIgnored private var messageProxy: MessageProxy?
    @ObservationIgnored private var navigationProxy: NavigationProxy?
    /// Applied once the freshly loaded document reports itself ready.
    @ObservationIgnored private var pendingPosition: TextPosition?
    @ObservationIgnored private var pendingFragment: String?
    @ObservationIgnored private var pendingGoToEnd = false
    /// Resize restore pin, kept across spine reloads while Draw is expanded.
    @ObservationIgnored private var pinnedRestorePosition: TextPosition?
    /// A `start` that arrived before the web view existed.
    @ObservationIgnored private var pendingStart: Locator?
    @ObservationIgnored private var hasStarted = false
    /// Fraction of the book each spine item accounts for, by byte size.
    @ObservationIgnored private var spineWeights: [Double] = []
    @ObservationIgnored private var spineOffsets: [Double] = []
    @ObservationIgnored private var viewportWidth: Double = 900
    @ObservationIgnored private var viewportHeight: Double = 0
    @ObservationIgnored private var viewportRelayoutWork: DispatchWorkItem?

    public init(settings: ReaderSettings = ReaderSettings()) {
        self.settings = settings
    }

    // MARK: - Web view lifecycle

    /// Builds the web view for a book. Called once per opened book.
    /// Builds the web view for a book, or returns the existing one.
    ///
    /// SwiftUI calls `makeNSView` several times while a `NavigationSplitView`
    /// settles its layout, and building a fresh web view each time would throw
    /// away the loaded chapter and reading position.
    public func makeWebView(for book: EPUBBook) -> WKWebView {
        if let existing = webView, self.book?.bookID == book.bookID {
            return existing
        }
        self.book = book
        computeSpineWeights(for: book)

        let handler = EPUBSchemeHandler(book: book)
        schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = true

        let proxy = MessageProxy(controller: self)
        messageProxy = proxy
        configuration.userContentController.add(proxy, name: "reader")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = false
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif

        let navigation = NavigationProxy(controller: self)
        navigationProxy = navigation
        webView.navigationDelegate = navigation

        self.webView = webView
        applyWebViewChromeColors()

        if let target = pendingStart {
            pendingStart = nil
            loadSpineItem(index: target.spineIndex, position: target.start)
        }
        return webView
    }

    public func tearDown() {
        viewportRelayoutWork?.cancel()
        viewportRelayoutWork = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView?.navigationDelegate = nil
        webView = nil
        messageProxy = nil
        navigationProxy = nil
        schemeHandler = nil
    }

    /// Records the current size so margins and column widths track the window,
    /// then re-pages once layout has settled.
    public func updateViewport(width: Double, height: Double = 0) {
        guard width > 0 else { return }
        let widthChanged = abs(width - viewportWidth) > 1
        let heightChanged = height > 0 && abs(height - viewportHeight) > 1
        guard widthChanged || heightChanged else { return }
        viewportWidth = width
        if height > 0 { viewportHeight = height }

        guard hasStarted, webView != nil else { return }
        scheduleViewportRelayout()
    }

    private func scheduleViewportRelayout() {
        viewportRelayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applySettings()
        }
        viewportRelayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    // MARK: - Opening content

    /// Begins reading at a saved position.
    ///
    /// SwiftUI may run the caller's `task` before the representable has built
    /// the web view, so the request is held and replayed from `makeWebView`
    /// rather than being dropped.
    public func start(at locator: Locator?, annotations: [Annotation]) {
        self.annotations = annotations

        // The view's task modifier can fire repeatedly; only the first start
        // should load, or every layout pass would reset the reader.
        guard !hasStarted else { return }
        hasStarted = true

        let target = locator ?? .startOfBook()
        guard webView != nil else {
            pendingStart = target
            return
        }
        loadSpineItem(index: target.spineIndex, position: target.start)
    }

    private func loadSpineItem(
        index: Int,
        position: TextPosition? = nil,
        fragment: String? = nil,
        goToEnd: Bool = false
    ) {
        guard let book, let webView else { return }
        let order = book.publication.readingOrder
        guard order.indices.contains(index) else { return }

        // Drop any live selection chip before the document changes.
        clearSelection()

        isLoading = true
        spineIndex = index
        chapterTitle = book.chapterTitle(forSpineIndex: index)
        pendingPosition = position
        pendingFragment = fragment
        pendingGoToEnd = goToEnd

        let url = EPUBSchemeHandler.url(forArchivePath: order[index].path)
        webView.load(URLRequest(url: url))
    }

    // MARK: - Navigation

    public func nextPage() {
        evaluate("__reader.nextPage()") { [weak self] result in
            guard let self, (result as? Bool) == false else { return }
            self.goToNextChapter()
        }
    }

    public func previousPage() {
        evaluate("__reader.previousPage()") { [weak self] result in
            guard let self, (result as? Bool) == false else { return }
            self.goToPreviousChapter()
        }
    }

    public func goToNextChapter() {
        guard let book else { return }
        let next = spineIndex + 1
        guard next < book.publication.readingOrder.count else { return }
        loadSpineItem(index: next)
    }

    public func goToPreviousChapter() {
        let previous = spineIndex - 1
        guard previous >= 0 else { return }
        // Entering from the right should land on that chapter's last page.
        loadSpineItem(index: previous, goToEnd: true)
    }

    public func go(to entry: TOCEntry) {
        guard let book, let index = book.publication.spineIndex(forPath: entry.path) else { return }
        if index == spineIndex, let fragment = entry.fragment {
            evaluate("__reader.goToFragment(\(jsString(fragment)), true)")
        } else {
            loadSpineItem(index: index, fragment: entry.fragment)
        }
    }

    public func go(to locator: Locator) {
        if locator.spineIndex == spineIndex {
            evaluate("__reader.goToPosition(\(json(locator.start)), true)")
        } else {
            loadSpineItem(index: locator.spineIndex, position: locator.start)
        }
    }

    /// Jumps to a fraction of the whole book, for the progress slider.
    public func seek(toProgress target: Double) {
        guard let book else { return }
        let clamped = min(max(target, 0), 1)
        let count = book.publication.readingOrder.count
        guard count > 0 else { return }

        var index = spineOffsets.lastIndex { $0 <= clamped } ?? 0
        index = min(index, count - 1)

        let start = spineOffsets[index]
        let weight = spineWeights[index]
        let withinChapter = weight > 0 ? (clamped - start) / weight : 0

        if index == spineIndex {
            evaluate("__reader.goToPage(Math.round((__reader.state().pageCount - 1) * \(withinChapter)), false)")
        } else {
            loadSpineItem(index: index)
        }
    }

    // MARK: - Annotations

    public func setAnnotations(_ annotations: [Annotation]) {
        self.annotations = annotations
        pushHighlights()
    }

    public func clearSelection() {
        selection = nil
        evaluate("__reader.clearSelection()")
    }

    /// Sentences remaining in the current spine item, from `position` or the page.
    public func extractUtterances(
        from position: TextPosition?,
        completion: @escaping ([ReaderUtterance]) -> Void
    ) {
        let argument = position.map { json($0) } ?? "null"
        evaluate("__reader.extractUtterances(\(argument))") { result in
            completion(Self.decodeUtterances(result))
        }
    }

    /// Paints a live read-aloud overlay. Pass `nil` to clear it.
    public func setReadingRange(_ locator: Locator?, charStart: Int? = nil, charEnd: Int? = nil) {
        guard let locator else {
            evaluate("__reader.setReadingRange(null)")
            return
        }
        var payload: [String: Any] = [
            "start": [
                "elementPath": locator.start.elementPath,
                "offset": locator.start.offset,
            ],
            "end": [
                "elementPath": (locator.end ?? locator.start).elementPath,
                "offset": (locator.end ?? locator.start).offset,
            ],
        ]
        if let charStart { payload["charStart"] = charStart }
        if let charEnd { payload["charEnd"] = charEnd }
        guard let encoded = jsonString(payload) else { return }
        let startArg = charStart.map(String.init) ?? "null"
        let endArg = charEnd.map(String.init) ?? "null"
        evaluate("__reader.setReadingRange(\(encoded), \(startArg), \(endArg))")
    }

    /// Turns to the page that contains `position` without animating.
    public func revealForReading(_ position: TextPosition) {
        evaluate("__reader.goToPosition(\(json(position)), false)")
    }

    /// Pins resize restore to this position so inspector expansion cannot jump to chapter start.
    public func pinRestore(to position: TextPosition?) {
        if let position, !position.elementPath.isEmpty {
            pinnedRestorePosition = position
            evaluate("__reader.pinRestore(\(json(position)))")
        } else {
            pinnedRestorePosition = nil
            evaluate("__reader.pinRestore(null)")
        }
    }

    private func pushPinRestore() {
        guard let position = pinnedRestorePosition else { return }
        evaluate("__reader.pinRestore(\(json(position)))")
    }

    private func pushHighlights() {
        let visible = annotations.filter { $0.locator.spineIndex == spineIndex }
        let payloads = visible.map(\.javaScriptPayload)
        guard
            let data = try? JSONSerialization.data(withJSONObject: payloads),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluate("__reader.setHighlights(\(json))")
    }

    // MARK: - Settings

    private func applySettings() {
        applyWebViewChromeColors()
        guard let options = jsonString(settings.runtimeOptions(forWidth: viewportWidth)) else { return }
        evaluate("__reader.configure(\(options), true)")
    }

    /// Paint WKWebView’s under-page / layer with the theme so scroll never flashes white.
    private func applyWebViewChromeColors() {
        #if os(macOS)
        guard let webView else { return }
        let color = settings.theme.nsBackgroundColor
        webView.underPageBackgroundColor = color
        webView.wantsLayer = true
        webView.layer?.backgroundColor = color.cgColor
        #endif
    }

    // MARK: - Message handling

    fileprivate func reportLoadFailure(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    fileprivate func handle(message body: [String: Any]) {
        guard let type = body["type"] as? String else { return }

        switch type {
        case "domReady":
            startRuntime()
        case "ready":
            handleReady(body)
        case "pageChanged":
            handlePageChanged(body)
        case "selection":
            handleSelection(body)
        case "selectionCleared":
            selection = nil
        case "highlightTapped":
            handleHighlightTapped(body)
        case "highlightsResolved":
            handleHighlightsResolved(body)
        case "link":
            handleLink(body)
        case "reachedEnd":
            goToNextChapter()
        case "reachedStart":
            goToPreviousChapter()
        case "error":
            let context = body["context"] as? String ?? "reader"
            let message = body["message"] as? String ?? "unknown error"
            errorMessage = "\(context): \(message)"
        default:
            break
        }
    }

    private func startRuntime() {
        var options = settings.runtimeOptions(forWidth: viewportWidth)
        options["spineIndex"] = spineIndex
        guard let encoded = jsonString(options) else { return }
        evaluate("__reader.start(\(encoded))")
    }

    private func handleReady(_ body: [String: Any]) {
        pageCount = body["pageCount"] as? Int ?? 1

        if pendingGoToEnd {
            evaluate("__reader.goToEnd()")
        } else if let fragment = pendingFragment {
            evaluate("__reader.goToFragment(\(jsString(fragment)), false)")
        } else if let position = pendingPosition, !position.elementPath.isEmpty {
            evaluate("__reader.goToPosition(\(json(position)), false)")
        }

        pendingGoToEnd = false
        pendingFragment = nil
        pendingPosition = nil

        pushHighlights()
        pushPinRestore()
        // Evaluations run in order, so this reports the position after any
        // restore above has been applied. Without it, opening a book at its
        // first page would never emit a position or update progress.
        evaluate("__reader.notifyState()")
        isLoading = false
    }

    private func handlePageChanged(_ body: [String: Any]) {
        // Column paging leaves the DOM selection intact; dismiss the palette.
        if selection != nil {
            clearSelection()
        }

        page = body["page"] as? Int ?? 0
        pageCount = max(1, body["pageCount"] as? Int ?? 1)

        let withinChapter = body["progression"] as? Double ?? 0
        progress = overallProgress(spineIndex: spineIndex, withinChapter: withinChapter)

        guard
            let raw = body["position"] as? [String: Any],
            let position = decodePosition(raw)
        else { return }

        onPositionChanged?(
            Locator(spineIndex: spineIndex, start: position, totalProgression: progress)
        )
    }

    private func handleSelection(_ body: [String: Any]) {
        guard
            let text = body["text"] as? String,
            let locatorBody = body["locator"] as? [String: Any],
            let startRaw = locatorBody["start"] as? [String: Any],
            let start = decodePosition(startRaw)
        else { return }

        let end = (locatorBody["end"] as? [String: Any]).flatMap(decodePosition)
        let rect = decodeRect(body["rect"] as? [String: Any])

        selection = ReaderSelection(
            text: text,
            locator: Locator(spineIndex: spineIndex, start: start, end: end, text: text),
            rect: rect
        )
    }

    private func handleHighlightTapped(_ body: [String: Any]) {
        guard
            let idString = body["id"] as? String,
            let id = UUID(uuidString: idString)
        else { return }
        onHighlightActivated?(id, decodeRect(body["rect"] as? [String: Any]))
    }

    private func handleHighlightsResolved(_ body: [String: Any]) {
        guard let rawResults = body["results"] as? [[String: Any]] else { return }

        let resolutions: [AnchorResolution] = rawResults.compactMap { raw in
            guard
                let idString = raw["id"] as? String,
                let id = UUID(uuidString: idString),
                let statusRaw = raw["status"] as? String,
                let status = AnchorStatus(rawValue: statusRaw)
            else { return nil }

            var repaired: Locator?
            if status == .repaired, let locatorBody = raw["locator"] as? [String: Any] {
                guard
                    let startRaw = locatorBody["start"] as? [String: Any],
                    let start = decodePosition(startRaw)
                else { return AnchorResolution(id: id, status: status) }
                let end = (locatorBody["end"] as? [String: Any]).flatMap(decodePosition)
                repaired = Locator(spineIndex: spineIndex, start: start, end: end)
            }
            return AnchorResolution(id: id, status: status, locator: repaired)
        }

        // Keep the in-memory annotation list in sync so later paints use the
        // repaired locators without waiting for a store round-trip.
        if !resolutions.isEmpty {
            for resolution in resolutions {
                guard let index = annotations.firstIndex(where: { $0.id == resolution.id }) else {
                    continue
                }
                annotations[index].anchorStatus = resolution.status
                if let locator = resolution.locator {
                    annotations[index].locator = locator
                }
            }
            onAnchorsResolved?(resolutions)
        }
    }

    private func handleLink(_ body: [String: Any]) {
        guard let href = body["href"] as? String, let book else { return }

        // External links open in the browser; internal ones move the reader.
        if let url = URL(string: href), let scheme = url.scheme,
           scheme == "http" || scheme == "https" || scheme == "mailto" {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
            return
        }

        let order = book.publication.readingOrder
        guard order.indices.contains(spineIndex) else { return }

        let (rawPath, fragment) = EPUBPath.splitFragment(href)
        if rawPath.isEmpty {
            evaluate("__reader.goToFragment(\(jsString(fragment ?? "")), true)")
            return
        }

        let resolved = EPUBPath.resolve(href: rawPath, relativeTo: order[spineIndex].path)
        guard let index = book.publication.spineIndex(forPath: resolved) else { return }
        loadSpineItem(index: index, fragment: fragment)
    }

    // MARK: - Progress weighting

    /// Chapters are weighted by uncompressed byte size, so the progress bar
    /// tracks how much reading is left rather than how many files are left.
    private func computeSpineWeights(for book: EPUBBook) {
        let order = book.publication.readingOrder
        let sizes = order.map { max(1, Double(book.container.uncompressedSize(at: $0.path))) }
        let total = sizes.reduce(0, +)

        guard total > 0 else {
            let uniform = 1.0 / Double(max(1, order.count))
            spineWeights = Array(repeating: uniform, count: order.count)
            spineOffsets = (0..<order.count).map { Double($0) * uniform }
            return
        }

        spineWeights = sizes.map { $0 / total }
        var running = 0.0
        spineOffsets = spineWeights.map { weight in
            defer { running += weight }
            return running
        }
    }

    private func overallProgress(spineIndex: Int, withinChapter: Double) -> Double {
        guard spineOffsets.indices.contains(spineIndex) else { return 0 }
        let start = spineOffsets[spineIndex]
        let weight = spineWeights[spineIndex]
        return min(1, max(0, start + weight * min(max(withinChapter, 0), 1)))
    }

    // MARK: - Bridging helpers

    /// Runs a script against the current document.
    ///
    /// Failures are swallowed: a chapter can finish loading between the call
    /// and its evaluation, which invalidates the script through no fault of
    /// the caller, and the reader recovers on the next document's `ready`.
    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else {
            completion?(nil)
            return
        }
        webView.evaluateJavaScript(script) { result, _ in
            completion?(result)
        }
    }

    #if DEBUG
    /// Test hook for inspecting the live document.
    func evaluateForTesting(_ script: String, completion: @escaping (Any?) -> Void) {
        evaluate(script, completion: completion)
    }
    #endif

    private func decodePosition(_ raw: [String: Any]) -> TextPosition? {
        guard let path = raw["elementPath"] as? [Int] else { return nil }
        return TextPosition(elementPath: path, offset: raw["offset"] as? Int ?? 0)
    }

    private static func decodeUtterances(_ result: Any?) -> [ReaderUtterance] {
        let rows: [[String: Any]]
        if let string = result as? String,
           let data = string.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = parsed
        } else if let parsed = result as? [[String: Any]] {
            rows = parsed
        } else {
            return []
        }

        return rows.compactMap { raw in
            guard
                let text = raw["text"] as? String,
                let startRaw = raw["start"] as? [String: Any],
                let endRaw = raw["end"] as? [String: Any],
                let startPath = intPath(startRaw["elementPath"]),
                let endPath = intPath(endRaw["elementPath"])
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ReaderUtterance(
                text: trimmed,
                start: TextPosition(elementPath: startPath, offset: intValue(startRaw["offset"])),
                end: TextPosition(elementPath: endPath, offset: intValue(endRaw["offset"]))
            )
        }
    }

    private static func intPath(_ raw: Any?) -> [Int]? {
        guard let array = raw as? [Any] else { return raw as? [Int] }
        return array.map(intValue)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let value = raw as? Int { return value }
        return 0
    }

    private func decodeRect(_ raw: [String: Any]?) -> CGRect {
        guard let raw else { return .zero }
        return CGRect(
            x: raw["x"] as? Double ?? 0,
            y: raw["y"] as? Double ?? 0,
            width: raw["width"] as? Double ?? 0,
            height: raw["height"] as? Double ?? 0
        )
    }

    private func json(_ position: TextPosition) -> String {
        let object: [String: Any] = [
            "elementPath": position.elementPath,
            "offset": position.offset,
        ]
        return jsonString(object) ?? "{}"
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

// MARK: - Delegate proxies

/// Holds the controller weakly, because `WKUserContentController` retains its
/// message handlers and would otherwise keep the controller alive forever.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var controller: ReaderController?

    init(controller: ReaderController) {
        self.controller = controller
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        controller?.handle(message: body)
    }
}

private final class NavigationProxy: NSObject, WKNavigationDelegate {
    weak var controller: ReaderController?

    init(controller: ReaderController) {
        self.controller = controller
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Only our own scheme may load; reader.js intercepts real links and
        // reports them so the controller can decide what to do.
        guard let url = navigationAction.request.url else {
            return decisionHandler(.cancel)
        }
        decisionHandler(url.scheme == EPUBSchemeHandler.scheme ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        controller?.reportLoadFailure(error.localizedDescription)
    }

    /// Almost always a missing sandbox entitlement or a memory kill. Without
    /// surfacing it the window just stays blank with no clue why.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        controller?.reportLoadFailure("The rendering process stopped unexpectedly.")
    }
}
