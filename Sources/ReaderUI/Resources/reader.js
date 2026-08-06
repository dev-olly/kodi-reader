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
   * See reader.css for the derivation.
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

  function measure() {
    var total = document.documentElement.scrollWidth;
    var stride = state.stride || window.innerWidth;
    // Subtract a little so a document that fits exactly does not round up.
    state.pageCount = Math.max(1, Math.ceil((total - 2) / stride));
    state.currentPage = clamp(
      Math.round(document.documentElement.scrollLeft / stride),
      0,
      state.pageCount - 1
    );
  }

  function clamp(value, low, high) {
    return Math.min(high, Math.max(low, value));
  }

  function relayout(preservedPosition) {
    applyLayout();
    measure();
    if (preservedPosition) {
      goToPosition(preservedPosition, false);
    }
    renderHighlights();
  }

  // ------------------------------------------------------------ navigation

  function scrollToPage(page, animated) {
    var target = clamp(page, 0, state.pageCount - 1) * state.stride;
    var behavior = animated && settings.animatePageTurns ? "smooth" : "auto";
    try {
      document.documentElement.scrollTo({ left: target, top: 0, behavior: behavior });
    } catch (error) {
      document.documentElement.scrollLeft = target;
    }
    state.currentPage = clamp(page, 0, state.pageCount - 1);
  }

  function goToPage(page, animated) {
    scrollToPage(page, animated !== false);
    notifyPageChanged();
  }

  /*
   * Returns false when the move would run off the end of the document, which
   * the app treats as a signal to load the neighbouring spine item.
   */
  function nextPage() {
    if (state.currentPage >= state.pageCount - 1) return false;
    goToPage(state.currentPage + 1, true);
    return true;
  }

  function previousPage() {
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
    var absolute = rect.left + document.documentElement.scrollLeft;
    return clamp(Math.floor(absolute / state.stride), 0, state.pageCount - 1);
  }

  function notifyPageChanged() {
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
    var pageStart = state.currentPage * state.stride;
    var pageEnd = pageStart + state.stride;
    var scrollLeft = document.documentElement.scrollLeft;
    var layer = document.getElementById(LAYER_ID);

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
        if (element.id === LAYER_ID) return NodeFilter.FILTER_REJECT;
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

    var scrollLeft = document.documentElement.scrollLeft;
    var scrollTop = document.documentElement.scrollTop;
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
        if (highlight.note) div.dataset.hasNote = "true";
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

  // ----------------------------------------------------------------- theme

  function applyStyles(variables) {
    var root = document.documentElement;
    Object.keys(variables || {}).forEach(function (key) {
      root.style.setProperty(key, variables[key]);
    });
  }

  /* Typography changes reflow the text, so re-page around the current spot. */
  function configure(options, preservePosition) {
    var anchor = preservePosition === false ? null : currentPosition();
    Object.keys(options || {}).forEach(function (key) {
      if (key in settings) settings[key] = options[key];
    });
    if (options && options.variables) applyStyles(options.variables);
    relayout(anchor);
    notifyPageChanged();
  }

  // ----------------------------------------------------------------- input

  function onClick(event) {
    var link = event.target && event.target.closest ? event.target.closest("a") : null;
    if (link && link.getAttribute("href")) {
      event.preventDefault();
      post({ type: "link", href: link.getAttribute("href") });
      return;
    }

    if (!settings.edgeTapPaging) return;
    var selection = window.getSelection();
    if (selection && !selection.isCollapsed) return;

    var ratio = event.clientX / window.innerWidth;
    if (ratio < 0.15) {
      if (!previousPage()) post({ type: "reachedStart" });
    } else if (ratio > 0.85) {
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
    var anchor = currentPosition();
    if (resizeTimer) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      relayout(anchor);
      notifyPageChanged();
    }, 90);
  }

  // ------------------------------------------------------------------ boot

  function start(options) {
    try {
      if (options) {
        Object.keys(options).forEach(function (key) {
          if (key in settings) settings[key] = options[key];
        });
        if (options.variables) applyStyles(options.variables);
        if (typeof options.spineIndex === "number") state.spineIndex = options.spineIndex;
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
    goToEnd: function () {
      measure();
      goToPage(state.pageCount - 1, false);
    },
    setHighlights: setHighlights,
    clearSelection: clearSelection,
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
      notifyPageChanged();
    },
    state: function () {
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
