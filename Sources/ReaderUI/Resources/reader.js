/*
 * Reader runtime injected into every spine document.
 *
 * Responsibilities: lay the document out into pages, move between them,
 * translate between DOM ranges and the durable locators the app persists,
 * report text selections, and paint the highlight overlay.
 *
 * Everything the app calls lives on `window.__reader`; everything the app
 * hears about arrives through the `reader` message handler.
 */
(function () {
  "use strict";

  var LAYER_ID = "reader-highlight-layer";
  var READING_LAYER_ID = "reader-reading-layer";

  var settings = {
    marginX: 72,
    marginY: 56,
    twoPageSpread: true,
    twoPageMinWidth: 1100,
    edgeTapPaging: true,
    animatePageTurns: true,
  };

  var state = {
    spineIndex: 0,
    pageCount: 1,
    currentPage: 0,
    stride: 0,
    columns: 1,
    highlights: [],
    ready: false,
  };

  // ---------------------------------------------------------------- bridge

  function post(message) {
    try {
      window.webkit.messageHandlers.reader.postMessage(message);
    } catch (error) {
      /* Running outside the app; nothing is listening. */
    }
  }

  function reportError(context, error) {
    post({
      type: "error",
      context: context,
      message: error && error.message ? error.message : String(error),
    });
  }

  // ---------------------------------------------------------------- layout

  function columnCount() {
    if (!settings.twoPageSpread) return 1;
    return window.innerWidth >= settings.twoPageMinWidth ? 2 : 1;
  }

  /*
   * The column gap is pinned to twice the horizontal margin so that a page
   * advance is always exactly one viewport width, for any column count.
   * reader.css enforces the matching body padding. See reader.css.
   */
  function applyLayout() {
    var root = document.documentElement;
    var viewport = window.innerWidth;
    var margin = settings.marginX;
    var gap = margin * 2;
    var columns = columnCount();
    var columnWidth = (viewport - 2 * margin - (columns - 1) * gap) / columns;

    root.style.setProperty("--page-margin-x", margin + "px");
    root.style.setProperty("--page-margin-y", settings.marginY + "px");
    root.style.setProperty("--column-gap", gap + "px");
    root.style.setProperty("--column-width", Math.max(120, columnWidth) + "px");

    state.columns = columns;
    state.stride = viewport;
  }

  function parsePx(value) {
    var n = parseFloat(value);
    return isFinite(n) ? n : 0;
  }

  /*
   * Live column stride, measured from the body's box rather than assumed
   * from innerWidth. When the page-box invariant holds (padding = marginX,
   * gap = 2 * marginX) this equals the viewport width; if a book still
   * bends the box, paging follows the real column pitch instead of drifting.
   */
  function currentStride() {
    try {
      var root = document.documentElement;
      var body = document.body;
      if (!body) return window.innerWidth || state.stride || 1;
      var style = window.getComputedStyle(body);
      var gapRaw = style.columnGap;
      var gap = !gapRaw || gapRaw === "normal" ? 0 : parsePx(gapRaw);
      var stride =
        root.clientWidth -
        parsePx(style.marginLeft) -
        parsePx(style.marginRight) -
        parsePx(style.paddingLeft) -
        parsePx(style.paddingRight) +
        gap;
      if (isFinite(stride) && stride > 0) return stride;
    } catch (error) {
      /* Fall through to the viewport fallback. */
    }
    return window.innerWidth || state.stride || 1;
  }

  function scrollingRoot() {
    return document.scrollingElement || document.documentElement;
  }

  function getScrollLeft() {
    return scrollingRoot().scrollLeft;
  }

  function setScrollLeft(target, behavior) {
    var root = scrollingRoot();
    var html = document.documentElement;
    var body = document.body;
    if (behavior && behavior !== "auto") {
      try {
        root.scrollTo({ left: target, top: 0, behavior: behavior });
      } catch (error) {
        root.scrollLeft = target;
      }
      return;
    }
    try {
      root.scrollTo({ left: target, top: 0, behavior: "auto" });
    } catch (error) {
      /* Fall through to the assignment below. */
    }
    root.scrollLeft = target;
    html.scrollLeft = target;
    if (body) body.scrollLeft = target;
    void html.offsetWidth;
    if (Math.abs(getScrollLeft() - target) > 2) {
      root.scrollLeft = target;
      html.scrollLeft = target;
      if (body) body.scrollLeft = target;
    }
  }

  function maxScrollLeft() {
    var el = scrollingRoot();
    return Math.max(0, el.scrollWidth - el.clientWidth);
  }

  function clamp(value, low, high) {
    return Math.min(high, Math.max(low, value));
  }

  /*
   * Page index implied by the live scroll offset. The DOM is the source of
   * truth; state.currentPage is only allowed to lead during a smooth turn.
   */
  function pageFromScroll() {
    var stride = currentStride();
    return clamp(
      Math.round(getScrollLeft() / stride),
      0,
      Math.max(0, state.pageCount - 1)
    );
  }

  // Intended page while a smooth scroll is in flight; null otherwise.
  var pendingPageTarget = null;

  function syncPageFromScroll() {
    var actual = pageFromScroll();
    if (pendingPageTarget == null) {
      state.currentPage = actual;
      return actual;
    }
    var expected = pendingPageTarget * currentStride();
    if (Math.abs(getScrollLeft() - expected) <= 2) {
      pendingPageTarget = null;
      state.currentPage = actual;
      return actual;
    }
    state.currentPage = clamp(pendingPageTarget, 0, state.pageCount - 1);
    return state.currentPage;
  }

  function measure() {
    var stride = currentStride();
    state.stride = stride;
    // Round rather than ceil: sub-pixel scrollWidth slop from column gaps must
    // not invent a trailing page that has no content to scroll to.
    state.pageCount = Math.max(1, Math.round(maxScrollLeft() / stride) + 1);
    syncPageFromScroll();
  }

  function layoutSnapshot() {
    var el = document.documentElement;
    return {
      width: window.innerWidth,
      clientWidth: el.clientWidth,
      scrollWidth: el.scrollWidth,
      maxScroll: maxScrollLeft(),
    };
  }

  function snapshotsEqual(a, b) {
    return (
      a &&
      b &&
      Math.abs(a.width - b.width) < 1 &&
      Math.abs(a.clientWidth - b.clientWidth) < 1 &&
      Math.abs(a.scrollWidth - b.scrollWidth) < 1 &&
      Math.abs(a.maxScroll - b.maxScroll) < 1
    );
  }

  var relayoutGeneration = 0;
  // First valid text anchor captured while overlapping resize/configure
  // relayouts are in flight. Later captures often see scrollLeft already
  // reset to 0 and would restore the chapter start by mistake.
  var pendingRestore = null;
  // When set (Draw expanded), resize restore always uses this locator.
  var pinnedRestore = null;
  // One-shot resize anchor: captured before an imminent width change (e.g.
  // opening the sidebar note editor) and consumed by the next relayout.
  var pinnedRestoreOnce = null;

  function pinRestore(position) {
    if (position && position.elementPath && position.elementPath.length > 0) {
      pinnedRestore = position;
    } else {
      pinnedRestore = null;
    }
  }

  function pinRestoreCurrentOnce() {
    var p = currentPosition();
    if (p && p.elementPath && p.elementPath.length > 0) {
      pinnedRestoreOnce = p;
    }
  }

  function rememberRestore(position) {
    if (pinnedRestore) {
      pendingRestore = pinnedRestore;
      return;
    }
    if (pinnedRestoreOnce) {
      pendingRestore = pinnedRestoreOnce;
      pinnedRestoreOnce = null;
      return;
    }
    if (pendingRestore) return;
    if (!position || !position.elementPath || position.elementPath.length === 0) return;
    pendingRestore = position;
  }

  function relayout(preservedPosition) {
    rememberRestore(preservedPosition);
    applyLayout();
    // Flush pending custom properties so column metrics match the new viewport.
    void document.documentElement.offsetWidth;

    var generation = ++relayoutGeneration;
    pendingPageTarget = null;
    var last = null;
    var stableCount = 0;
    var attempts = 0;
    var maxAttempts = 8;

    function finish() {
      if (generation !== relayoutGeneration) return;
      var restore = pendingRestore;
      pendingRestore = null;
      measure();
      pendingPageTarget = null;
      if (restore) {
        goToPosition(restore, false);
      } else {
        notifyPageChanged();
      }
      renderHighlights();
      renderReadingRange();
    }

    function step() {
      if (generation !== relayoutGeneration) return;
      applyLayout();
      void document.documentElement.offsetWidth;
      var now = layoutSnapshot();
      attempts += 1;
      if (snapshotsEqual(last, now)) {
        stableCount += 1;
      } else {
        stableCount = 0;
        last = now;
      }
      if (stableCount >= 1 || attempts >= maxAttempts) {
        finish();
        return;
      }
      scheduleStep();
    }

    // rAF is preferred, but it may never fire in a hidden WKWebView (tests,
    // background windows), so every step also has a timeout fallback.
    function scheduleStep() {
      var fired = false;
      function run() {
        if (fired) return;
        fired = true;
        step();
      }
      if (typeof requestAnimationFrame === "function") {
        requestAnimationFrame(run);
      }
      setTimeout(run, 16);
    }

    scheduleStep();
  }

  // ------------------------------------------------------------ navigation

  function scrollToPage(page, animated) {
    var stride = currentStride();
    // Clamp to the real scrollable range so an over-counted pageCount can never
    // send the caret past the last column, which would read as "the counter
    // moved but the page didn't".
    var requested = clamp(page, 0, state.pageCount - 1);
    var target = clamp(requested * stride, 0, maxScrollLeft());
    var useSmooth = animated && settings.animatePageTurns;

    if (useSmooth) {
      pendingPageTarget = clamp(Math.round(target / stride), 0, state.pageCount - 1);
      state.currentPage = pendingPageTarget;
      setScrollLeft(target, "smooth");
      return;
    }

    pendingPageTarget = null;
    setScrollLeft(target, "auto");
    state.currentPage = pageFromScroll();
  }

  function goToPage(page, animated) {
    scrollToPage(page, animated !== false);
    notifyPageChanged();
  }

  /*
   * Returns false when the move would run off the end of the document, which
   * the app treats as a signal to load the neighbouring spine item.
   */
  /*
   * Refresh pageCount against the live layout. Mid-animation we keep the
   * intended page; otherwise the DOM scroll offset wins so a resize that
   * reset scrollLeft cannot leave next/previous walking a ghost index.
   */
  function remeasureBounds() {
    var stride = currentStride();
    state.stride = stride;
    state.pageCount = Math.max(1, Math.round(maxScrollLeft() / stride) + 1);
    syncPageFromScroll();
  }

  function nextPage() {
    remeasureBounds();
    if (state.currentPage >= state.pageCount - 1) return false;
    goToPage(state.currentPage + 1, true);
    return true;
  }

  function previousPage() {
    remeasureBounds();
    if (state.currentPage <= 0) return false;
    goToPage(state.currentPage - 1, true);
    return true;
  }

  function goToFragment(fragment, animated) {
    if (!fragment) {
      goToPage(0, false);
      return true;
    }
    var element =
      document.getElementById(fragment) ||
      document.querySelector('[name="' + cssEscape(fragment) + '"]');
    if (!element) return false;

    var page = pageForRect(element.getBoundingClientRect());
    goToPage(page, animated === true);
    return true;
  }

  function cssEscape(value) {
    if (window.CSS && window.CSS.escape) return window.CSS.escape(value);
    return String(value).replace(/["\\]/g, "\\$&");
  }

  function pageForRect(rect) {
    if (!rect || (rect.width === 0 && rect.height === 0)) return state.currentPage;
    var stride = currentStride();
    var absolute = rect.left + getScrollLeft();
    return clamp(Math.floor(absolute / stride), 0, state.pageCount - 1);
  }

  function notifyPageChanged() {
    if (pendingPageTarget == null) {
      syncPageFromScroll();
    }
    post({
      type: "pageChanged",
      spineIndex: state.spineIndex,
      page: state.currentPage,
      pageCount: state.pageCount,
      progression: state.pageCount > 1 ? state.currentPage / (state.pageCount - 1) : 0,
      position: currentPosition(),
    });
  }

  // -------------------------------------------------------------- locators

  /*
   * A position is the chain of childNode indices from <body> down to a text
   * node, plus a character offset. Indices stay valid because the document is
   * immutable, and unlike a scroll offset the anchor survives resizing and
   * font changes. The highlight layer is always body's last child so it never
   * shifts the indices of real content.
   */
  function pathOfNode(node) {
    var path = [];
    var current = node;
    while (current && current !== document.body) {
      var parent = current.parentNode;
      if (!parent) break;
      path.unshift(Array.prototype.indexOf.call(parent.childNodes, current));
      current = parent;
    }
    return path;
  }

  function nodeAtPath(path) {
    var node = document.body;
    for (var i = 0; i < path.length; i++) {
      var next = node.childNodes[path[i]];
      // A missing step must fail hard: falling back to a parent would make a
      // broken locator look resolved and skip quote-based repair.
      if (!next) return null;
      node = next;
    }
    return node;
  }

  function positionFromPoint(x, y) {
    if (!document.caretRangeFromPoint) return null;
    var range = document.caretRangeFromPoint(x, y);
    if (!range) return null;

    // A point over padding or between blocks resolves to an element rather
    // than a text node, and an element path rooted at <body> is empty, which
    // would be useless for restoring the position later.
    var node = range.startContainer;
    if (node === document.body) return null;
    if (node.nodeType !== Node.TEXT_NODE && node.nodeType !== Node.ELEMENT_NODE) return null;

    return { elementPath: pathOfNode(node), offset: range.startOffset };
  }

  /*
   * Anchor for the start of whatever is currently on screen.
   *
   * Probing straight down the inside edge of the first column finds the top
   * line in reading order for both one and two column layouts. If the page
   * opens with an image or the probes all land in gaps, fall back to walking
   * the text nodes for the first one laid out on this page.
   */
  function currentPosition() {
    var x = settings.marginX + 4;
    var usableHeight = Math.max(1, window.innerHeight - 2 * settings.marginY);

    for (var fraction = 0; fraction < 1; fraction += 0.08) {
      var y = settings.marginY + 2 + fraction * usableHeight;
      var position = positionFromPoint(x, y);
      if (position) return position;
    }

    return firstVisibleAnchor();
  }

  /*
   * First node laid out on the current page. Text is preferred, but a cover or
   * full-page illustration has none, so elements are searched too rather than
   * returning an empty path that would collapse to the top of the chapter.
   */
  function firstVisibleAnchor() {
    var stride = currentStride();
    var pageStart = state.currentPage * stride;
    var pageEnd = pageStart + stride;
    var scrollLeft = getScrollLeft();
    var layer = document.getElementById(LAYER_ID);
    var readingLayer = document.getElementById(READING_LAYER_ID);

    function isOnThisPage(rect) {
      if (rect.width === 0 && rect.height === 0) return false;
      var left = rect.left + scrollLeft;
      return left >= pageStart - 2 && left < pageEnd;
    }

    var textWalker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.textContent || !node.textContent.trim()) {
          return NodeFilter.FILTER_REJECT;
        }
        if (layer && layer.contains(node)) return NodeFilter.FILTER_REJECT;
        if (readingLayer && readingLayer.contains(node)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    var node;
    while ((node = textWalker.nextNode())) {
      var range = document.createRange();
      range.selectNodeContents(node);
      if (isOnThisPage(range.getBoundingClientRect())) {
        return { elementPath: pathOfNode(node), offset: 0 };
      }
    }

    var elementWalker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (element) {
        if (element.id === LAYER_ID || element.id === READING_LAYER_ID) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    var element;
    while ((element = elementWalker.nextNode())) {
      if (isOnThisPage(element.getBoundingClientRect())) {
        return { elementPath: pathOfNode(element), offset: 0 };
      }
    }

    return { elementPath: [], offset: 0 };
  }

  function rangeFromPosition(position) {
    try {
      var node = nodeAtPath(position.elementPath || []);
      if (!node) return null;
      var range = document.createRange();
      var maxOffset =
        node.nodeType === Node.TEXT_NODE
          ? node.textContent.length
          : node.childNodes.length;
      var offset = clamp(position.offset || 0, 0, maxOffset);
      range.setStart(node, offset);
      range.setEnd(node, offset);
      return range;
    } catch (error) {
      return null;
    }
  }

  function rangeFromLocator(locator) {
    try {
      var startNode = nodeAtPath((locator.start && locator.start.elementPath) || []);
      var endNode = nodeAtPath(
        ((locator.end || locator.start) && (locator.end || locator.start).elementPath) || []
      );
      if (!startNode || !endNode) return null;
      var range = document.createRange();

      var startMax =
        startNode.nodeType === Node.TEXT_NODE
          ? startNode.textContent.length
          : startNode.childNodes.length;
      var endMax =
        endNode.nodeType === Node.TEXT_NODE
          ? endNode.textContent.length
          : endNode.childNodes.length;

      range.setStart(startNode, clamp((locator.start && locator.start.offset) || 0, 0, startMax));
      range.setEnd(
        endNode,
        clamp(((locator.end || locator.start) && (locator.end || locator.start).offset) || 0, 0, endMax)
      );
      return range.collapsed ? null : range;
    } catch (error) {
      return null;
    }
  }

  function goToPosition(position, animated) {
    if (!position || !position.elementPath || position.elementPath.length === 0) {
      goToPage(0, false);
      return;
    }
    var range = rangeFromPosition(position);
    if (!range) {
      goToPage(0, false);
      return;
    }

    // A collapsed range has no box, so widen it by one character to measure.
    var rect = range.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) {
      try {
        var node = range.startContainer;
        if (node.nodeType === Node.TEXT_NODE && node.textContent.length > range.startOffset) {
          range.setEnd(node, range.startOffset + 1);
          rect = range.getBoundingClientRect();
        } else if (node.nodeType === Node.ELEMENT_NODE) {
          rect = node.getBoundingClientRect();
        }
      } catch (error) {
        /* Fall through with the empty rect; pageForRect handles it. */
      }
    }
    goToPage(pageForRect(rect), animated === true);
  }

  // ------------------------------------------------------------- selection

  var selectionTimer = null;

  function handleSelectionChange() {
    if (selectionTimer) clearTimeout(selectionTimer);
    selectionTimer = setTimeout(reportSelection, 120);
  }

  function reportSelection() {
    var selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
      post({ type: "selectionCleared" });
      return;
    }

    var range = selection.getRangeAt(0);
    var text = selection.toString().trim();
    if (!text) {
      post({ type: "selectionCleared" });
      return;
    }

    var rects = range.getClientRects();
    var anchor = rects.length > 0 ? rects[rects.length - 1] : range.getBoundingClientRect();

    post({
      type: "selection",
      text: text,
      spineIndex: state.spineIndex,
      locator: {
        start: {
          elementPath: pathOfNode(range.startContainer),
          offset: range.startOffset,
        },
        end: {
          elementPath: pathOfNode(range.endContainer),
          offset: range.endOffset,
        },
      },
      // Viewport coordinates, for placing the popover on the Swift side.
      rect: {
        x: anchor.left,
        y: anchor.top,
        width: anchor.width,
        height: anchor.height,
      },
    });
  }

  function clearSelection() {
    var selection = window.getSelection();
    if (selection) selection.removeAllRanges();
  }

  // ------------------------------------------------------------ highlights

  function highlightLayer() {
    var layer = document.getElementById(LAYER_ID);
    if (!layer) {
      layer = document.createElement("div");
      layer.id = LAYER_ID;
      // Appending last keeps every other child's index stable, which the
      // locator paths depend on.
      document.body.appendChild(layer);
      layer.addEventListener("click", onHighlightClick);
    }
    return layer;
  }

  function onHighlightClick(event) {
    var target = event.target;
    if (!target || !target.dataset || !target.dataset.highlightId) return;
    event.preventDefault();
    event.stopPropagation();

    var rect = target.getBoundingClientRect();
    post({
      type: "highlightTapped",
      id: target.dataset.highlightId,
      rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
    });
  }

  function setHighlights(highlights) {
    state.highlights = Array.isArray(highlights) ? highlights : [];
    renderHighlights();
  }

  function normalizeWhitespace(value) {
    return String(value || "")
      .replace(/\s+/g, " ")
      .trim();
  }

  /*
   * When a locator is stale, find the stored quote in the document and rebuild
   * a locator from the first match. Whitespace is collapsed so soft hyphens
   * and line breaks in the EPUB do not defeat the search.
   */
  function rangeFromQuote(quote) {
    var needle = normalizeWhitespace(quote);
    if (!needle) return null;

    var layer = document.getElementById(LAYER_ID);
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (layer && layer.contains(node)) return NodeFilter.FILTER_REJECT;
        var readingLayer = document.getElementById(READING_LAYER_ID);
        if (readingLayer && readingLayer.contains(node)) return NodeFilter.FILTER_REJECT;
        if (!node.textContent || !node.textContent.trim()) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    var nodes = [];
    var full = "";
    var map = []; // full-string index → { node, offset }
    var node;
    while ((node = walker.nextNode())) {
      var text = node.textContent;
      for (var i = 0; i < text.length; i++) {
        var ch = text.charAt(i);
        if (/\s/.test(ch)) {
          if (full.length === 0 || full.charAt(full.length - 1) === " ") continue;
          full += " ";
          map.push({ node: node, offset: i });
        } else {
          full += ch;
          map.push({ node: node, offset: i });
        }
      }
      nodes.push(node);
    }
    full = full.replace(/\s+$/, "");

    var index = full.indexOf(needle);
    if (index < 0) return null;

    var startInfo = map[index];
    var endInfo = map[index + needle.length - 1];
    if (!startInfo || !endInfo) return null;

    try {
      var range = document.createRange();
      range.setStart(startInfo.node, startInfo.offset);
      range.setEnd(endInfo.node, endInfo.offset + 1);
      return range;
    } catch (error) {
      return null;
    }
  }

  function locatorPayloadFromRange(range) {
    return {
      start: {
        elementPath: pathOfNode(range.startContainer),
        offset: range.startOffset,
      },
      end: {
        elementPath: pathOfNode(range.endContainer),
        offset: range.endOffset,
      },
    };
  }

  /*
   * Resolve each highlight: use the locator when it still works, otherwise
   * repair from the stored quote, otherwise mark orphaned and skip painting.
   */
  function resolveHighlight(highlight) {
    var range = rangeFromLocator(highlight);
    if (range) {
      return { status: "resolved", range: range, locator: null };
    }

    if (highlight.text) {
      var repaired = rangeFromQuote(highlight.text);
      if (repaired) {
        return {
          status: "repaired",
          range: repaired,
          locator: locatorPayloadFromRange(repaired),
        };
      }
    }

    return { status: "orphaned", range: null, locator: null };
  }

  function renderHighlights() {
    var layer = highlightLayer();
    layer.textContent = "";
    if (state.highlights.length === 0) {
      post({ type: "highlightsResolved", results: [] });
      return;
    }

    var scrollLeft = getScrollLeft();
    var scrollTop = scrollingRoot().scrollTop;
    var fragment = document.createDocumentFragment();
    var results = [];

    for (var i = 0; i < state.highlights.length; i++) {
      var highlight = state.highlights[i];
      var resolved = resolveHighlight(highlight);
      var entry = { id: highlight.id, status: resolved.status };
      if (resolved.locator) entry.locator = resolved.locator;
      results.push(entry);

      if (!resolved.range) continue;

      // Keep the in-memory highlight locator updated so later paints work.
      if (resolved.locator) {
        highlight.start = resolved.locator.start;
        highlight.end = resolved.locator.end;
      }

      var rects = resolved.range.getClientRects();
      for (var r = 0; r < rects.length; r++) {
        var rect = rects[r];
        if (rect.width < 1 || rect.height < 1) continue;

        var div = document.createElement("div");
        div.className = "reader-highlight-rect";
        div.dataset.highlightId = highlight.id;
        div.dataset.style = highlight.style || "fill";
        if (highlight.hasNote && r === 0) div.dataset.hasNote = "true";
        div.style.left = rect.left + scrollLeft + "px";
        div.style.top = rect.top + scrollTop + "px";
        div.style.width = rect.width + "px";
        div.style.height = rect.height + "px";
        div.style.backgroundColor = highlight.color || "rgba(255, 214, 69, 0.45)";
        if (highlight.style === "underline") {
          div.style.setProperty("--highlight-underline-color", highlight.color);
        }
        fragment.appendChild(div);
      }
    }
    layer.appendChild(fragment);
    post({ type: "highlightsResolved", results: results });
  }

  // ---------------------------------------------------------- read aloud

  var readingRange = null;
  var MAX_UTTERANCE_CHARS = 1600;
  var MIN_UTTERANCE_CHARS = 60;
  var SKIP_SPEAK_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, SVG: 1, RT: 1, RP: 1 };

  function readingLayer() {
    var layer = document.getElementById(READING_LAYER_ID);
    if (!layer) {
      layer = document.createElement("div");
      layer.id = READING_LAYER_ID;
      document.body.appendChild(layer);
    }
    return layer;
  }

  function isSpeakableTextNode(node) {
    if (!node || !node.textContent) return false;
    var highlight = document.getElementById(LAYER_ID);
    var reading = document.getElementById(READING_LAYER_ID);
    if (highlight && highlight.contains(node)) return false;
    if (reading && reading.contains(node)) return false;
    var el = node.parentElement;
    while (el && el !== document.body) {
      if (SKIP_SPEAK_TAGS[el.tagName]) return false;
      if (el.hasAttribute("hidden") || el.getAttribute("aria-hidden") === "true") {
        return false;
      }
      el = el.parentElement;
    }
    return true;
  }

  function collectSpeakableNodes() {
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        return isSpeakableTextNode(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      },
    });
    var nodes = [];
    var node;
    while ((node = walker.nextNode())) nodes.push(node);
    return nodes;
  }

  function blockParent(node) {
    var el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    while (el && el !== document.body) {
      var display = "";
      try {
        display = window.getComputedStyle(el).display;
      } catch (error) {
        display = "";
      }
      if (
        display === "block" ||
        display === "list-item" ||
        display === "table" ||
        display === "flex" ||
        display === "grid" ||
        /^(P|H1|H2|H3|H4|H5|H6|LI|BLOCKQUOTE|PRE|DIV|SECTION|ARTICLE|FIGCAPTION|DT|DD|TR)$/.test(
          el.tagName
        )
      ) {
        return el;
      }
      el = el.parentElement;
    }
    return el || document.body;
  }

  function isSentenceTerminator(ch, next) {
    if (ch !== "." && ch !== "!" && ch !== "?") return false;
    if (!next) return true;
    return /\s/.test(next);
  }

  function flushUtterance(pieces, start, end, utterances) {
    if (end <= start) return;
    var raw = "";
    var i;
    for (i = start; i < end; i++) raw += pieces[i].ch;
    var text = raw.replace(/\s+/g, " ").trim();
    if (!text || text.length < 1) return;
    if (!/[A-Za-z0-9\u00C0-\u024F]/.test(text)) return;

    var first = pieces[start];
    var last = pieces[end - 1];
    var from = start;
    var to = end - 1;
    while (from < end && /\s/.test(pieces[from].ch)) from++;
    while (to > from && /\s/.test(pieces[to].ch)) to--;
    if (from > to) return;
    first = pieces[from];
    last = pieces[to];

    utterances.push({
      text: text,
      start: { elementPath: pathOfNode(first.node), offset: first.offset },
      end: { elementPath: pathOfNode(last.node), offset: last.offset + 1 },
    });
  }

  function splitLongUtterances(utterances) {
    var result = [];
    for (var i = 0; i < utterances.length; i++) {
      var item = utterances[i];
      if (item.text.length <= MAX_UTTERANCE_CHARS) {
        result.push(item);
        continue;
      }
      var words = item.text.split(" ");
      var chunk = "";
      for (var w = 0; w < words.length; w++) {
        var next = chunk ? chunk + " " + words[w] : words[w];
        if (next.length > MAX_UTTERANCE_CHARS && chunk) {
          result.push({
            text: chunk,
            start: item.start,
            end: item.end,
          });
          chunk = words[w];
        } else {
          chunk = next;
        }
      }
      if (chunk) {
        result.push({
          text: chunk,
          start: item.start,
          end: item.end,
        });
      }
    }
    return result;
  }

  function mergeShortUtterances(utterances) {
    if (utterances.length < 2) return utterances;
    var result = [];
    var i = 0;
    while (i < utterances.length) {
      var current = utterances[i];
      while (
        current.text.length < MIN_UTTERANCE_CHARS &&
        i + 1 < utterances.length &&
        current.text.length + 1 + utterances[i + 1].text.length <= MAX_UTTERANCE_CHARS
      ) {
        var next = utterances[i + 1];
        current = {
          text: current.text + " " + next.text,
          start: current.start,
          end: next.end,
        };
        i++;
      }
      result.push(current);
      i++;
    }
    return result;
  }

  var SURROUNDING_BLOCK_RADIUS = 2;
  var SURROUNDING_MAX_CHARS = 2400;

  function blockPlainText(block) {
    var parts = [];
    var i;
    for (i = 0; i < block.nodes.length; i++) {
      parts.push(block.nodes[i].textContent || "");
    }
    return parts.join("").replace(/\s+/g, " ").trim();
  }

  function textBeforeInBlock(block, node, offset) {
    var out = "";
    var i;
    for (i = 0; i < block.nodes.length; i++) {
      var n = block.nodes[i];
      if (n === node) {
        out += (n.textContent || "").slice(0, Math.max(0, offset));
        break;
      }
      out += n.textContent || "";
    }
    return out.replace(/\s+/g, " ").trim();
  }

  function textAfterInBlock(block, node, offset) {
    var out = "";
    var seen = false;
    var i;
    for (i = 0; i < block.nodes.length; i++) {
      var n = block.nodes[i];
      if (!seen) {
        if (n === node) {
          seen = true;
          out += (n.textContent || "").slice(Math.max(0, offset));
        }
        continue;
      }
      out += n.textContent || "";
    }
    return out.replace(/\s+/g, " ").trim();
  }

  function firstTextNode(node) {
    if (!node) return null;
    if (node.nodeType === Node.TEXT_NODE) return node;
    var walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, null);
    return walker.nextNode();
  }

  function groupSpeakableBlocks() {
    var nodes = collectSpeakableNodes();
    var blocks = [];
    var current = null;
    var i;
    for (i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (!/\S/.test(node.textContent || "")) continue;
      var parent = blockParent(node);
      if (!current || current.el !== parent) {
        current = { el: parent, nodes: [node] };
        blocks.push(current);
      } else {
        current.nodes.push(node);
      }
    }
    return blocks;
  }

  function blockContainsNode(block, node) {
    if (!node) return false;
    var i;
    for (i = 0; i < block.nodes.length; i++) {
      if (block.nodes[i] === node) return true;
    }
    return false;
  }

  function joinParagraphs(parts) {
    return parts.filter(function (part) { return part; }).join("\n\n");
  }

  function trimSurroundingWindow(before, quote, after) {
    function total() {
      return before.length + quote.length + after.length;
    }
    while (total() > SURROUNDING_MAX_CHARS && (before || after)) {
      if (before.length >= after.length) {
        var cut = before.indexOf("\n\n");
        if (cut >= 0) {
          before = before.slice(cut + 2);
        } else {
          before = "";
        }
      } else {
        var last = after.lastIndexOf("\n\n");
        if (last >= 0) {
          after = after.slice(0, last);
        } else {
          after = "";
        }
      }
    }
    return { before: before, after: after };
  }

  function extractSurroundingPassage(start, end) {
    var empty = { before: "", quote: "", after: "" };
    if (!start || !start.elementPath) return empty;

    var startNode = firstTextNode(nodeAtPath(start.elementPath));
    var endPos = end && end.elementPath ? end : start;
    var endNode = firstTextNode(nodeAtPath(endPos.elementPath)) || startNode;
    if (!startNode || !endNode) return empty;

    var startOffset = start.offset || 0;
    var endOffset = endPos.offset != null ? endPos.offset : startOffset;
    var blocks = groupSpeakableBlocks();
    if (!blocks.length) return empty;

    var firstHit = -1;
    var lastHit = -1;
    var i;
    for (i = 0; i < blocks.length; i++) {
      if (blockContainsNode(blocks[i], startNode) || blockContainsNode(blocks[i], endNode)) {
        if (firstHit < 0) firstHit = i;
        lastHit = i;
      }
    }
    if (firstHit < 0) {
      var startBlock = blockParent(startNode);
      var endBlock = blockParent(endNode);
      for (i = 0; i < blocks.length; i++) {
        if (blocks[i].el === startBlock || blocks[i].el === endBlock) {
          if (firstHit < 0) firstHit = i;
          lastHit = i;
        }
      }
    }
    if (firstHit < 0) return empty;

    var from = Math.max(0, firstHit - SURROUNDING_BLOCK_RADIUS);
    var to = Math.min(blocks.length - 1, lastHit + SURROUNDING_BLOCK_RADIUS);

    var quote = "";
    try {
      var range = document.createRange();
      range.setStart(startNode, Math.min(startOffset, startNode.textContent.length));
      range.setEnd(endNode, Math.min(endOffset, endNode.textContent.length));
      quote = range.toString().replace(/\s+/g, " ").trim();
    } catch (error) {
      quote = "";
    }

    var beforeParts = [];
    for (i = from; i < firstHit; i++) {
      beforeParts.push(blockPlainText(blocks[i]));
    }
    beforeParts.push(textBeforeInBlock(blocks[firstHit], startNode, startOffset));

    var afterParts = [];
    afterParts.push(textAfterInBlock(blocks[lastHit], endNode, endOffset));
    for (i = lastHit + 1; i <= to; i++) {
      afterParts.push(blockPlainText(blocks[i]));
    }

    var trimmed = trimSurroundingWindow(
      joinParagraphs(beforeParts),
      quote,
      joinParagraphs(afterParts)
    );
    return { before: trimmed.before, quote: quote, after: trimmed.after };
  }

  function extractUtterances(fromPosition) {
    var nodes = collectSpeakableNodes();
    if (!nodes.length) return [];

    var startNode = null;
    var startOffset = 0;
    var origin = fromPosition;
    if (!origin || !origin.elementPath || !origin.elementPath.length) {
      origin = currentPosition();
    }
    if (origin && origin.elementPath && origin.elementPath.length) {
      startNode = nodeAtPath(origin.elementPath);
      startOffset = origin.offset || 0;
    }

    var pieces = [];
    var started = !startNode;
    var i;
    for (i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (!started) {
        if (node !== startNode) continue;
        started = true;
      }
      var text = node.textContent || "";
      var from = node === startNode ? Math.min(Math.max(startOffset, 0), text.length) : 0;
      var o;
      for (o = from; o < text.length; o++) {
        pieces.push({ ch: text.charAt(o), node: node, offset: o });
      }
    }
    if (!pieces.length) return [];

    var utterances = [];
    var start = 0;
    var lastBlock = blockParent(pieces[0].node);
    for (i = 0; i < pieces.length; i++) {
      var piece = pieces[i];
      var block = blockParent(piece.node);
      if (block !== lastBlock && i > start) {
        flushUtterance(pieces, start, i, utterances);
        start = i;
        lastBlock = block;
      }
      var nextCh = i + 1 < pieces.length ? pieces[i + 1].ch : "";
      if (isSentenceTerminator(piece.ch, nextCh)) {
        flushUtterance(pieces, start, i + 1, utterances);
        start = i + 1;
      }
    }
    flushUtterance(pieces, start, pieces.length, utterances);
    return mergeShortUtterances(splitLongUtterances(utterances));
  }

  function subrangeByCharOffsets(range, charStart, charEnd) {
    if (!range || charStart == null || charEnd == null) return range;
    var startBound = Math.max(0, charStart);
    var endBound = Math.max(startBound, charEnd);
    var walker = document.createTreeWalker(
      range.commonAncestorContainer,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode: function (node) {
          if (!range.intersectsNode(node)) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        },
      }
    );

    var counted = 0;
    var startNode = null;
    var startOff = 0;
    var endNode = null;
    var endOff = 0;
    var node;
    while ((node = walker.nextNode())) {
      var text = node.textContent || "";
      var nodeStart = 0;
      var nodeEnd = text.length;
      if (node === range.startContainer) nodeStart = range.startOffset;
      if (node === range.endContainer) nodeEnd = range.endOffset;
      if (nodeStart >= nodeEnd) continue;

      var length = nodeEnd - nodeStart;
      if (!startNode && counted + length > startBound) {
        startNode = node;
        startOff = nodeStart + (startBound - counted);
      }
      if (counted + length >= endBound) {
        endNode = node;
        endOff = nodeStart + (endBound - counted);
        break;
      }
      counted += length;
    }

    if (!startNode) return range;
    try {
      var sliced = document.createRange();
      sliced.setStart(startNode, startOff);
      sliced.setEnd(endNode || startNode, endNode ? endOff : startOff + 1);
      return sliced.collapsed ? range : sliced;
    } catch (error) {
      return range;
    }
  }

  function setReadingRange(locator, charStart, charEnd) {
    if (!locator) {
      readingRange = null;
      renderReadingRange();
      return;
    }
    readingRange = {
      start: locator.start,
      end: locator.end || locator.start,
      charStart: charStart,
      charEnd: charEnd,
    };
    renderReadingRange();
  }

  function renderReadingRange() {
    var layer = readingLayer();
    layer.textContent = "";
    if (!readingRange) return;

    var range = rangeFromLocator(readingRange);
    if (!range) return;
    range = subrangeByCharOffsets(range, readingRange.charStart, readingRange.charEnd);
    if (!range) return;

    var scrollLeft = getScrollLeft();
    var scrollTop = scrollingRoot().scrollTop;
    var rects = range.getClientRects();
    var fragment = document.createDocumentFragment();
    for (var r = 0; r < rects.length; r++) {
      var rect = rects[r];
      if (rect.width < 1 || rect.height < 1) continue;
      var div = document.createElement("div");
      div.className = "reader-reading-rect";
      div.style.left = rect.left + scrollLeft + "px";
      div.style.top = rect.top + scrollTop + "px";
      div.style.width = rect.width + "px";
      div.style.height = rect.height + "px";
      fragment.appendChild(div);
    }
    layer.appendChild(fragment);
  }

  // ----------------------------------------------------------------- theme

  var SURFACE_ATTR = "data-reader-surface";
  var LIGHT_BG_LUMINANCE = 0.6;

  function applyStyles(variables) {
    var root = document.documentElement;
    Object.keys(variables || {}).forEach(function (key) {
      root.style.setProperty(key, variables[key]);
    });
    // Paint chrome immediately (with !important) so author sheets like
    // Gutenberg's `body { background-color: white }` cannot flash on scroll.
    var pageBg = (variables && variables["--color-background"]) || "";
    if (pageBg) {
      root.style.setProperty("background-color", pageBg, "important");
      if (document.body) {
        document.body.style.setProperty("background-color", pageBg, "important");
        if (variables["--color-text"]) {
          document.body.style.setProperty("color", variables["--color-text"], "important");
        }
      }
      root.style.setProperty("color-scheme", pageIsDark() ? "dark" : "light");
    }
    remapAuthorSurfaces();
  }

  function parseRGBA(color) {
    if (!color || color === "transparent") return null;
    var match = /^rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s*,\s*([0-9.]+))?\s*\)$/.exec(
      color
    );
    if (!match) return null;
    return {
      r: Number(match[1]),
      g: Number(match[2]),
      b: Number(match[3]),
      a: match[4] === undefined ? 1 : Number(match[4]),
    };
  }

  function relativeLuminance(r, g, b) {
    function channel(value) {
      var c = value / 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  }

  function pageIsDark() {
    var bg = getComputedStyle(document.documentElement).getPropertyValue("--color-background").trim();
    if (!bg) return false;
    // Hex from our theme variables (#rrggbb).
    var hex = /^#([0-9a-f]{6})$/i.exec(bg);
    if (hex) {
      var n = parseInt(hex[1], 16);
      return relativeLuminance((n >> 16) & 255, (n >> 8) & 255, n & 255) < 0.5;
    }
    var rgba = parseRGBA(bg);
    return rgba ? relativeLuminance(rgba.r, rgba.g, rgba.b) < 0.5 : false;
  }

  function clearRemappedSurfaces() {
    var nodes = document.querySelectorAll("[" + SURFACE_ATTR + "]");
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].style.removeProperty("background-color");
      nodes[i].removeAttribute(SURFACE_ATTR);
    }
  }

  function isReaderChrome(el) {
    if (!el || el.nodeType !== 1) return true;
    if (el.id === LAYER_ID || el.id === READING_LAYER_ID) return true;
    if (
      el.classList &&
      (el.classList.contains("reader-highlight-rect") ||
        el.classList.contains("reader-highlight-layer") ||
        el.classList.contains("reader-reading-rect"))
    ) {
      return true;
    }
    return !!(el.closest && (el.closest("#" + LAYER_ID) || el.closest("#" + READING_LAYER_ID)));
  }

  /*
   * EPUB callouts often keep a light paper fill in dark mode while we force
   * light text — remap those fills to --color-surface so the box stays visible
   * and readable.
   */
  function remapAuthorSurfaces() {
    clearRemappedSurfaces();
    if (!pageIsDark() || !document.body) return;

    var elements = document.body.querySelectorAll("*");
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      if (isReaderChrome(el)) continue;

      var rgba = parseRGBA(getComputedStyle(el).backgroundColor);
      if (!rgba || rgba.a < 0.08) continue;
      if (relativeLuminance(rgba.r, rgba.g, rgba.b) < LIGHT_BG_LUMINANCE) continue;

      el.style.setProperty("background-color", "var(--color-surface)", "important");
      el.setAttribute(SURFACE_ATTR, "1");
    }
  }

  /* Typography changes reflow the text, so re-page around the current spot. */
  function configure(options, preservePosition) {
    var anchor = preservePosition === false ? null : currentPosition();
    Object.keys(options || {}).forEach(function (key) {
      if (key in settings) settings[key] = options[key];
    });
    if (options && options.variables) applyStyles(options.variables);
    else remapAuthorSurfaces();
    relayout(anchor);
  }

  // ----------------------------------------------------------------- input

  function onClick(event) {
    var target = event.target;
    var link = target && target.closest ? target.closest("a") : null;
    if (link && link.getAttribute("href")) {
      event.preventDefault();
      post({ type: "link", href: link.getAttribute("href") });
      return;
    }

    if (!settings.edgeTapPaging) return;
    var selection = window.getSelection();
    if (selection && !selection.isCollapsed) return;

    // Highlight rects sit over the text; never steal those clicks for paging.
    if (target && target.closest && target.closest("#" + LAYER_ID)) return;

    // Only the empty page chrome (padding on body/html) is a tap zone.
    // Clicks on paragraphs, images, and other content must not turn the page.
    if (target !== document.body && target !== document.documentElement) return;

    var margin = settings.marginX;
    if (event.clientX < margin) {
      if (!previousPage()) post({ type: "reachedStart" });
    } else if (event.clientX > window.innerWidth - margin) {
      if (!nextPage()) post({ type: "reachedEnd" });
    }
  }

  function onWheel(event) {
    // Trackpad horizontal swipes should page rather than scroll the columns.
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
    event.preventDefault();
    if (wheelCooldown) return;

    if (event.deltaX > 24) {
      if (!nextPage()) post({ type: "reachedEnd" });
      startWheelCooldown();
    } else if (event.deltaX < -24) {
      if (!previousPage()) post({ type: "reachedStart" });
      startWheelCooldown();
    }
  }

  var wheelCooldown = false;
  function startWheelCooldown() {
    wheelCooldown = true;
    setTimeout(function () {
      wheelCooldown = false;
    }, 320);
  }

  var resizeTimer = null;
  function onResize() {
    if (resizeTimer) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      // Capture the anchor after the window has settled, not on the first
      // intermediate resize event, so we restore what is actually on screen.
      // A pinned locator (Draw) wins over the on-screen probe.
      relayout(pinnedRestore || pinnedRestoreOnce || currentPosition());
    }, 90);
  }

  // ------------------------------------------------------------------ boot

  function start(options) {
    try {
      // Theme variables first — before layout — so page turns never flash white paper.
      if (options && options.variables) applyStyles(options.variables);

      if (options) {
        Object.keys(options).forEach(function (key) {
          if (key in settings) settings[key] = options[key];
        });
        if (!options.variables) remapAuthorSurfaces();
        if (typeof options.spineIndex === "number") state.spineIndex = options.spineIndex;
      } else {
        remapAuthorSurfaces();
      }

      applyLayout();
      measure();

      document.addEventListener("selectionchange", handleSelectionChange);
      document.addEventListener("click", onClick, true);
      window.addEventListener("resize", onResize);
      window.addEventListener("wheel", onWheel, { passive: false });

      state.ready = true;
      post({
        type: "ready",
        spineIndex: state.spineIndex,
        pageCount: state.pageCount,
        title: document.title || null,
      });
    } catch (error) {
      reportError("start", error);
    }
  }

  window.__reader = {
    start: start,
    configure: configure,
    goToPage: goToPage,
    nextPage: nextPage,
    previousPage: previousPage,
    goToFragment: goToFragment,
    goToPosition: goToPosition,
    pinRestore: pinRestore,
    pinRestoreCurrentOnce: pinRestoreCurrentOnce,
    goToEnd: function () {
      measure();
      goToPage(state.pageCount - 1, false);
    },
    setHighlights: setHighlights,
    clearSelection: clearSelection,
    extractUtterances: function (fromPosition) {
      try {
        return JSON.stringify(extractUtterances(fromPosition));
      } catch (error) {
        reportError("extractUtterances", error);
        return "[]";
      }
    },
    extractSurroundingPassage: function (start, end) {
      try {
        return JSON.stringify(extractSurroundingPassage(start, end));
      } catch (error) {
        reportError("extractSurroundingPassage", error);
        return JSON.stringify({ before: "", quote: "", after: "" });
      }
    },
    setReadingRange: setReadingRange,
    /*
     * Re-measures and reports where we are. The app calls this once a freshly
     * loaded document has been positioned, so that opening a book emits a
     * position even when no restore or fragment jump was needed.
     */
    notifyState: function () {
      measure();
      notifyPageChanged();
    },
    relayout: function () {
      relayout(currentPosition());
    },
    state: function () {
      remeasureBounds();
      return {
        spineIndex: state.spineIndex,
        page: state.currentPage,
        pageCount: state.pageCount,
        position: currentPosition(),
      };
    },
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      post({ type: "domReady" });
    });
  } else {
    post({ type: "domReady" });
  }
})();
