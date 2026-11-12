(function () {
  "use strict";
  const boot = window.__KODI_BOOT__;
  const invoke = (args) => window.__TAURI_INTERNALS__.invoke("reader_event", args);
  window.__kodiPost = function (message) {
    invoke({ sessionId: boot.sessionId, documentId: boot.documentId, message }).catch(() => {});
  };
  const colors = { yellow: "rgba(255,214,69,.45)", green: "rgba(100,190,130,.38)", blue: "rgba(100,165,235,.38)", pink: "rgba(235,120,175,.35)", purple: "rgba(175,130,225,.35)" };
  window.__kodiRefresh = function (next) {
    const reader = window.__reader;
    if (!reader) return;
    const settings = next.settings;
    const dark = settings.theme === "dark" || (settings.theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
    const sepia = settings.theme === "sepia";
    reader.configure({ marginX: settings.margin, twoPageSpread: settings.twoPageSpread, variables: {
      "--font-family": settings.fontFamily + ", Georgia, serif", "--font-size": settings.fontSize + "px", "--line-height": String(settings.lineHeight),
      "--color-background": dark ? "#202621" : sepia ? "#f2e8d5" : "#fafbf7", "--color-surface": dark ? "#2b332d" : "#f2f4ec",
      "--color-text": dark ? "#e5eadd" : "#253d30", "--color-link": dark ? "#9bc9ad" : "#38734c", "--color-selection": "rgba(120,180,140,.35)"
    } });
    reader.setHighlights(next.annotations.filter(a => a.locator.spineIndex === boot.spineIndex).map(a => ({ id: a.id, text: a.text, start: a.locator.start, end: a.locator.end, color: colors[a.color] || colors.yellow, style: a.color === "underline" ? "underline" : "fill", hasNote: Boolean(a.note || a.sketches.length || a.audioRecordings.length) })));
    reader.setReminders(next.reminders.filter(r => !r.completed && r.locator.spineIndex === boot.spineIndex).map(r => ({ id: r.id, title: r.title, start: r.locator.start, end: r.locator.end })));
    reader.setReadingMarker(next.readingMarker && next.readingMarker.spineIndex === boot.spineIndex ? next.readingMarker : null);
  };
  document.addEventListener("DOMContentLoaded", () => {
    window.__reader.start({ spineIndex: boot.spineIndex, documentID: boot.documentId, edgeTapPaging: true });
    window.__kodiRefresh(boot);
    if (boot.fragment) window.__reader.goToFragment(boot.fragment);
    else if (boot.position?.spineIndex === boot.spineIndex && boot.position.desktopChapterEnd === true) window.__reader.goToEnd();
    else if (boot.position && boot.position.spineIndex === boot.spineIndex) window.__reader.goToPosition(boot.position.start, false);
    window.__reader.notifyState();
    if (boot.narration) window.__kodiPost({ type: 'narrationPassages', ticket: boot.narration.ticket, voice: boot.narration.voice, rate: boot.narration.rate, passages: JSON.parse(window.__reader.narrationPassages(boot.spineIndex, null, null, true)) });
  }, { once: true });
  document.addEventListener("keydown", event => {
    const reader = window.__reader;
    if (!reader || event.ctrlKey || event.altKey || event.metaKey || /INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) return;
    if (["ArrowRight", "PageDown", " "].includes(event.key)) { event.preventDefault(); if (!reader.nextPage()) window.__kodiPost({ type: "reachedEnd" }); }
    if (["ArrowLeft", "PageUp"].includes(event.key)) { event.preventDefault(); if (!reader.previousPage()) window.__kodiPost({ type: "reachedStart" }); }
    if (event.key.toLowerCase() === "m") { event.preventDefault(); if (event.shiftKey) window.__kodiPost({ type: "readingMarkerRequested" }); else reader.setReadingMarkerPlacement(true); }
    if (event.key === "Escape") reader.setReadingMarkerPlacement(false);
  });
})();
