import EpubKit
import Foundation
import Observation
import PDFKit
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

/// Neighboring paragraphs around a locator, used to give Ask AI more context.
public struct ReaderSurroundingPassage: Equatable, Sendable {
    public var before: String
    public var quote: String
    public var after: String

    public init(before: String = "", quote: String = "", after: String = "") {
        self.before = before
        self.quote = quote
        self.after = after
    }
}

/// Drives the web view: loads spine documents, moves between pages and
/// chapters, tracks position, and relays selections and highlights.
@Observable
public final class ReaderController {
    // MARK: - Observable state

    public private(set) var book: EPUBBook?
    public private(set) var pdfBook: PDFBook?
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
    public private(set) var visiblePageRange: ClosedRange<Int> = 0...0

    public var isPDF: Bool { pdfBook != nil }
    public var canNavigateSections: Bool {
        guard let pdfBook else { return true }
        return pdfBook.outline.flatMap(\.flattened).contains { $0.destination != nil }
    }

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
    /// Fires when an external web link is tapped, so the app can open it in-app.
    public var onExternalLink: ((URL) -> Void)?

    // MARK: - Private

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var pdfView: PDFView?
    @ObservationIgnored private var pdfObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var pdfHighlightAnnotations: [UUID: [PDFAnnotation]] = [:]
    @ObservationIgnored private var pdfLinkProxy: PDFLinkProxy?
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
            #if os(macOS)
            existing.identifier = ReaderKeyTarget.pageWebViewIdentifier
            #endif
            return existing
        }
        tearDownViews()
        self.book = book
        pdfBook = nil
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
        webView.identifier = ReaderKeyTarget.pageWebViewIdentifier
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

    /// Builds the native PDF view, or returns the existing instance.
    public func makePDFView(for book: PDFBook) -> PDFView {
        if let existing = pdfView, pdfBook?.bookID == book.bookID { return existing }
        tearDownViews()
        pdfBook = book
        self.book = nil

        let view = PDFView(frame: .zero)
        #if os(macOS)
        view.identifier = ReaderKeyTarget.pageWebViewIdentifier
        #endif
        view.document = book.document
        let linkProxy = PDFLinkProxy(controller: self)
        pdfLinkProxy = linkProxy
        view.delegate = linkProxy
        view.displayDirection = .horizontal
        view.displaysPageBreaks = true
        view.displaysAsBook = true
        view.autoScales = true
        pdfView = view
        installPDFObservers(on: view)
        configurePDFLayout()

        if hasStarted {
            startPDF(at: pendingStart)
            pendingStart = nil
        }
        return view
    }

    public func tearDown() {
        viewportRelayoutWork?.cancel()
        viewportRelayoutWork = nil
        tearDownViews()
        book = nil
        pdfBook = nil
    }

    private func tearDownViews() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView?.navigationDelegate = nil
        webView = nil
        messageProxy = nil
        navigationProxy = nil
        schemeHandler = nil
        pdfObserverTokens.forEach(NotificationCenter.default.removeObserver)
        pdfObserverTokens.removeAll()
        pdfHighlightAnnotations.removeAll()
        pdfView?.delegate = nil
        pdfLinkProxy = nil
        pdfView = nil
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

        if pdfView != nil {
            configurePDFLayout()
            return
        }

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

        let target = locator ?? (pdfBook == nil ? .startOfBook() : .pdfPage(0))
        if pdfBook != nil {
            startPDF(at: target)
            return
        }
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
        if let pdfView {
            clearSelection()
            pdfView.goToNextPage(nil)
            handlePDFPageChanged()
            return
        }
        evaluate("__reader.nextPage()") { [weak self] result in
            guard let self, (result as? Bool) == false else { return }
            self.goToNextChapter()
        }
    }

    public func previousPage() {
        if let pdfView {
            clearSelection()
            pdfView.goToPreviousPage(nil)
            handlePDFPageChanged()
            return
        }
        evaluate("__reader.previousPage()") { [weak self] result in
            guard let self, (result as? Bool) == false else { return }
            self.goToPreviousChapter()
        }
    }

    public func goToNextChapter() {
        if pdfBook != nil {
            goToAdjacentPDFOutline(forward: true)
            return
        }
        guard let book else { return }
        let next = spineIndex + 1
        guard next < book.publication.readingOrder.count else { return }
        loadSpineItem(index: next)
    }

    public func goToPreviousChapter() {
        if pdfBook != nil {
            goToAdjacentPDFOutline(forward: false)
            return
        }
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

    public func go(to destination: DocumentDestination) {
        switch destination {
        case .epub(let path, let fragment):
            go(to: TOCEntry(title: "", path: path, fragment: fragment))
        case .pdf(let pageIndex, let x, let y):
            goToPDFPage(pageIndex, point: x.flatMap { px in y.map { CGPoint(x: px, y: $0) } })
        }
    }

    public func go(to locator: Locator) {
        if locator.kind == .pdf {
            goToPDFPage(locator.spineIndex)
            return
        }
        if locator.spineIndex == spineIndex {
            evaluate("__reader.goToPosition(\(json(locator.start)), true)")
        } else {
            loadSpineItem(index: locator.spineIndex, position: locator.start)
        }
    }

    /// Jumps to a fraction of the whole book, for the progress slider.
    public func seek(toProgress target: Double) {
        if let pdfBook {
            let index = Int((min(max(target, 0), 1) * Double(max(0, pdfBook.pageCount - 1))).rounded())
            goToPDFPage(index)
            return
        }
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
        if pdfView != nil {
            pushPDFHighlights()
        } else {
            pushHighlights()
        }
    }

    public func clearSelection() {
        selection = nil
        if let pdfView {
            pdfView.clearSelection()
        } else {
            evaluate("__reader.clearSelection()")
        }
    }

    /// A few paragraphs around `locator`, capped so prompts stay small.
    public func extractSurroundingPassage(
        from locator: Locator,
        completion: @escaping (ReaderSurroundingPassage) -> Void
    ) {
        if locator.kind == .pdf {
            completion(pdfSurroundingPassage(for: locator))
            return
        }
        let start = json(locator.start)
        let end = json(locator.end ?? locator.start)
        evaluate("__reader.extractSurroundingPassage(\(start), \(end))") { result in
            completion(Self.decodeSurroundingPassage(result))
        }
    }

    /// Re-applies a reading position after the web view was temporarily taken
    /// out of the window (in-app browser preview).
    public func restorePosition(_ locator: Locator) {
        if locator.kind == .pdf {
            goToPDFPage(locator.spineIndex)
            return
        }
        pinRestoreOnce(to: locator.start)
        if locator.spineIndex == spineIndex {
            evaluate("__reader.goToPosition(\(json(locator.start)), false)")
        } else {
            loadSpineItem(index: locator.spineIndex, position: locator.start)
        }
    }

    /// Pins resize restore to this position so inspector expansion cannot jump to chapter start.
    public func pinRestore(to position: TextPosition?) {
        if pdfView != nil { return }
        if let position, !position.elementPath.isEmpty {
            pinnedRestorePosition = position
            evaluate("__reader.pinRestore(\(json(position)))")
        } else {
            pinnedRestorePosition = nil
            evaluate("__reader.pinRestore(null)")
        }
    }

    /// Captures the current on-screen position as a one-shot resize anchor so an
    /// imminent width change (opening/closing the sidebar note editor) restores here.
    public func pinRestoreCurrentPositionOnce() {
        if pdfView != nil { return }
        evaluate("__reader.pinRestoreCurrentOnce()")
    }

    /// Holds the leading reading passage across the complete lifetime of the
    /// Notes / Ask AI workspace, including both its opening and closing resize.
    public func beginWorkspaceRestore() {
        if pdfView != nil { return }
        evaluate("__reader.beginWorkspaceRestore()")
    }

    /// Releases the workspace anchor only after handing it to the closing
    /// resize, so the original leading passage cannot drift to the next column.
    public func endWorkspaceRestore() {
        if pdfView != nil { return }
        evaluate("__reader.endWorkspaceRestore()")
    }

    /// Uses a specific text position as the next resize anchor.
    public func pinRestoreOnce(to position: TextPosition) {
        if pdfView != nil { return }
        guard !position.elementPath.isEmpty else { return }
        evaluate("__reader.pinRestoreOnce(\(json(position)))")
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
        if pdfView != nil {
            configurePDFLayout()
            return
        }
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

    public func fitPDFPage() {
        guard let pdfView else { return }
        pdfView.autoScales = true
    }

    public func zoomPDFIn() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
    }

    public func zoomPDFOut() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
    }

    // MARK: - PDFKit

    private func installPDFObservers(on view: PDFView) {
        let center = NotificationCenter.default
        pdfObserverTokens = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                self?.handlePDFPageChanged()
            },
            center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
                self?.handlePDFSelectionChanged()
            },
            center.addObserver(forName: .PDFViewAnnotationHit, object: view, queue: .main) { [weak self] note in
                self?.handlePDFAnnotationHit(note)
            },
        ]
    }

    private func startPDF(at locator: Locator?) {
        guard let pdfBook else { return }
        pageCount = max(1, pdfBook.pageCount)
        goToPDFPage(locator?.spineIndex ?? 0)
        pushPDFHighlights()
        isLoading = false
    }

    private func configurePDFLayout() {
        guard let view = pdfView else { return }
        let index = currentPDFPageIndex()
        let useSpread = settings.twoPageSpread && viewportWidth >= 1100
        let wanted: PDFDisplayMode = useSpread ? .twoUp : .singlePage
        if view.displayMode != wanted {
            view.displayMode = wanted
            view.displaysAsBook = useSpread
            view.autoScales = true
            goToPDFPage(index, report: false)
        }
        updatePDFVisibleRange()
    }

    private func currentPDFPageIndex() -> Int {
        guard let pdfBook, let page = pdfView?.currentPage else { return spineIndex }
        let index = pdfBook.document.index(for: page)
        return index == NSNotFound ? spineIndex : index
    }

    private func goToPDFPage(_ requestedIndex: Int, point: CGPoint? = nil, report: Bool = true) {
        guard let pdfBook, let view = pdfView else { return }
        let index = min(max(0, requestedIndex), pdfBook.pageCount - 1)
        guard let target = pdfBook.document.page(at: index) else { return }
        if let point {
            view.go(to: PDFDestination(page: target, at: point))
        } else {
            view.go(to: target)
        }
        if report { handlePDFPageChanged() }
    }

    private func handlePDFPageChanged() {
        guard let pdfBook else { return }
        updatePDFVisibleRange()
        let index = visiblePageRange.lowerBound
        spineIndex = index
        page = index
        pageCount = max(1, pdfBook.pageCount)
        chapterTitle = pdfBook.sectionTitle(forPageIndex: index)
        progress = pageCount <= 1 ? 0 : Double(index) / Double(pageCount - 1)
        onPositionChanged?(.pdfPage(index, totalProgression: progress))
    }

    private func updatePDFVisibleRange() {
        guard let pdfBook, let view = pdfView else { return }
        let visible = view.visiblePages.compactMap { page -> Int? in
            let index = pdfBook.document.index(for: page)
            return index == NSNotFound ? nil : index
        }
        let lower = visible.min() ?? currentPDFPageIndex()
        let upper = visible.max() ?? lower
        visiblePageRange = lower...upper
    }

    private func goToAdjacentPDFOutline(forward: Bool) {
        guard let pdfBook else { return }
        let pages = pdfBook.outline.flatMap(\.flattened).compactMap { entry -> Int? in
            guard case .pdf(let page, _, _) = entry.destination else { return nil }
            return page
        }
        let unique = Array(Set(pages)).sorted()
        let target = forward
            ? unique.first(where: { $0 > spineIndex })
            : unique.last(where: { $0 < spineIndex })
        if let target { goToPDFPage(target) }
    }

    private func handlePDFSelectionChanged() {
        guard let pdfBook, let view = pdfView, pdfBook.allowsTextExtraction,
              let pdfSelection = view.currentSelection,
              let text = pdfSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            selection = nil
            return
        }

        var ranges: [PDFTextRange] = []
        var viewRect = CGRect.null
        for selectedPage in pdfSelection.pages {
            let pageIndex = pdfBook.document.index(for: selectedPage)
            guard pageIndex != NSNotFound else { continue }
            for index in 0..<pdfSelection.numberOfTextRanges(on: selectedPage) {
                let range = pdfSelection.range(at: index, on: selectedPage)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                ranges.append(PDFTextRange(pageIndex: pageIndex, location: range.location, length: range.length))
            }
            viewRect = viewRect.union(pdfOverlayRect(
                view.convert(pdfSelection.bounds(for: selectedPage), from: selectedPage),
                in: view
            ))
        }
        guard let first = ranges.first else { selection = nil; return }
        selection = ReaderSelection(
            text: text,
            locator: .pdfPage(first.pageIndex, ranges: ranges, text: text),
            rect: viewRect.isNull ? .zero : viewRect
        )
    }

    private func pushPDFHighlights() {
        guard let pdfBook else { return }
        for existing in pdfHighlightAnnotations.values.flatMap({ $0 }) {
            existing.page?.removeAnnotation(existing)
        }
        pdfHighlightAnnotations.removeAll()

        var resolutions: [AnchorResolution] = []
        for annotation in annotations where annotation.locator.kind == .pdf {
            let result = resolvePDFLocator(annotation.locator, quote: annotation.text)
            guard let locator = result.locator else {
                resolutions.append(AnchorResolution(id: annotation.id, status: .orphaned))
                continue
            }
            var rendered: [PDFAnnotation] = []
            for storedRange in locator.pdfRanges ?? [] {
                guard let page = pdfBook.document.page(at: storedRange.pageIndex),
                      let selected = page.selection(for: NSRange(location: storedRange.location, length: storedRange.length))
                else { continue }
                for line in selected.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard !bounds.isEmpty else { continue }
                    let subtype: PDFAnnotationSubtype = annotation.visibleHighlightColor == .underline
                        ? .underline
                        : .highlight
                    let highlight = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                    highlight.color = annotation.visibleHighlightColor.nsColor
                    highlight.userName = "kodi:\(annotation.id.uuidString)"
                    page.addAnnotation(highlight)
                    rendered.append(highlight)
                }
            }
            pdfHighlightAnnotations[annotation.id] = rendered
            let status: AnchorStatus = result.repaired ? .repaired : .resolved
            resolutions.append(AnchorResolution(id: annotation.id, status: status, locator: result.repaired ? locator : nil))
        }
        if !resolutions.isEmpty { onAnchorsResolved?(resolutions) }
    }

    private func resolvePDFLocator(_ locator: Locator, quote: String) -> (locator: Locator?, repaired: Bool) {
        guard let pdfBook, let ranges = locator.pdfRanges, !ranges.isEmpty else { return (nil, false) }
        let extracted = ranges.compactMap { item -> String? in
            guard let page = pdfBook.document.page(at: item.pageIndex) else { return nil }
            return page.selection(for: NSRange(location: item.location, length: item.length))?.string
        }.joined(separator: "\n")
        if normalizedPDFText(extracted) == normalizedPDFText(quote) { return (locator, false) }

        guard let page = pdfBook.document.page(at: locator.spineIndex),
              let pageText = page.string,
              let found = pageText.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive])
        else { return (nil, false) }
        let nsRange = NSRange(found, in: pageText)
        return (.pdfPage(locator.spineIndex, ranges: [PDFTextRange(
            pageIndex: locator.spineIndex,
            location: nsRange.location,
            length: nsRange.length
        )], totalProgression: locator.totalProgression, text: quote), true)
    }

    private func normalizedPDFText(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handlePDFAnnotationHit(_ notification: Notification) {
        let hit = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
        guard let marker = hit?.userName, marker.hasPrefix("kodi:"),
              let id = UUID(uuidString: String(marker.dropFirst(5))),
              let view = pdfView, let page = hit?.page
        else { return }
        let rect = pdfOverlayRect(view.convert(hit?.bounds ?? .zero, from: page), in: view)
        onHighlightActivated?(id, rect)
    }

    fileprivate func handlePDFLink(_ url: URL) {
        if let onExternalLink {
            onExternalLink(url)
        } else {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    private func pdfOverlayRect(_ rect: CGRect, in view: PDFView) -> CGRect {
        guard !view.isFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: view.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func pdfSurroundingPassage(for locator: Locator) -> ReaderSurroundingPassage {
        guard let pdfBook, let first = locator.pdfRanges?.first,
              let page = pdfBook.document.page(at: first.pageIndex), let pageText = page.string
        else { return ReaderSurroundingPassage(quote: locator.text ?? "") }
        let start = min(max(0, first.location), pageText.utf16.count)
        let end = min(pageText.utf16.count, start + max(0, first.length))
        let beforeStart = max(0, start - 1200)
        let afterEnd = min(pageText.utf16.count, end + 1200)
        let ns = pageText as NSString
        return ReaderSurroundingPassage(
            before: ns.substring(with: NSRange(location: beforeStart, length: start - beforeStart)),
            quote: locator.text ?? ns.substring(with: NSRange(location: start, length: end - start)),
            after: ns.substring(with: NSRange(location: end, length: afterEnd - end))
        )
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

        // Web links go in-app when the host wired a handler; mailto/tel stay
        // with the system default. Everything else is treated as in-book.
        if let url = URL(string: href), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                if let onExternalLink {
                    onExternalLink(url)
                } else {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #endif
                }
                return
            }
            if scheme == "mailto" || scheme == "tel" {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                return
            }
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

    private static func decodeSurroundingPassage(_ result: Any?) -> ReaderSurroundingPassage {
        let body: [String: Any]
        if let string = result as? String,
           let data = string.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = parsed
        } else if let parsed = result as? [String: Any] {
            body = parsed
        } else {
            return ReaderSurroundingPassage()
        }
        return ReaderSurroundingPassage(
            before: (body["before"] as? String) ?? "",
            quote: (body["quote"] as? String) ?? "",
            after: (body["after"] as? String) ?? ""
        )
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

private final class PDFLinkProxy: NSObject, PDFViewDelegate {
    weak var controller: ReaderController?

    init(controller: ReaderController) {
        self.controller = controller
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        controller?.handlePDFLink(url)
    }
}

#if os(macOS)
private extension HighlightColor {
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 1, green: 0.80, blue: 0.18, alpha: 0.48)
        case .green: return NSColor(calibratedRed: 0.42, green: 0.82, blue: 0.30, alpha: 0.44)
        case .blue: return NSColor(calibratedRed: 0.24, green: 0.62, blue: 0.96, alpha: 0.44)
        case .pink: return NSColor(calibratedRed: 1, green: 0.42, blue: 0.64, alpha: 0.44)
        case .purple: return NSColor(calibratedRed: 0.67, green: 0.43, blue: 0.94, alpha: 0.44)
        case .underline: return NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.05, alpha: 0.85)
        }
    }
}
#endif
