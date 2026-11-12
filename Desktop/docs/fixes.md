# Desktop fixes

Tracked from the November 11–12, 2026 desktop feedback. These checks concern the
separate desktop test app; Windows/Linux release acceptance remains pending.

- [x] Restore native Edit-menu paste shortcuts. Paste works in the Mac test app;
  code normalization tests cover leading zeros, whitespace and six/eight digits.
  The current signed-in account was preserved during the live check.
- [x] Correct the oversized note cursor and move the slash-command instructions
  outside the editable placeholder. Checked visually in the Mac test app.
- [x] Show `/sketch`, `/audio` and `/remind` choices when typing `/` on a new line.
  Enter runs the selected action. Code-block examples remain ordinary text.
- [x] `/sketch`: create and save the attachment before opening its canvas. Checked
  live in the isolated Desktop verification book.
- [x] `/remind`: open the reminder form with the supplied question and source
  passage. Checked live, then cancelled without creating a reminder.
- [x] Report failed actions and offer a safe retry. A restored slash command runs
  through Enter again; retrying an already-added sketch keeps its attachment ID.
- [x] `/audio`: the Mac review app starts, pauses and finishes native capture,
  saves AAC/M4A attachments, and plays them locally. Command routing, duplicate
  starts, save failures and cleanup also pass automated tests. On November 12 a
  spoken sample saved with 104 nonzero waveform buckets, decoded successfully
  and played to completion after reopening its note.
- [ ] Exercise microphone denial, device removal and sleep/resume on supported
  Windows/Linux systems; these remain separate native acceptance checks.
- [ ] Repeat paste and slash-command checks on supported Windows/Linux systems.
- [x] Remove a document from this device's Library while retaining its notes and
  attachments by default. Reimport clears the local visibility flag and restores
  the existing reading data. Cloud-only books remain visible; the visibility
  flag is excluded from Apple-compatible sync payloads.
- [x] Coordinate action menus across books, notes and attachments. Opening one
  closes the previous menu; selection, outside click, Escape, focus changes and
  window blur dismiss it. The existing design and menu structure are preserved.
- [x] Block duplicate removal submissions and prevent a pending removal dialog
  from being dismissed. Failed commands retain the dialog and allow retry.

See [native acceptance](native-acceptance.md) for the complete release checklist.

## Functional review against the Mac app

The existing visual design and Apple source are preserved. The review follows
actions through the desktop interface, Rust commands and durable library data.

Implemented corrections include:

- Continue mixed imports after a bad file and publish successful imports.
- Restore missing/corrupt originals on reimport without resetting notes.
- Remove owned originals and media after a successful full deletion, preserving
  assets still referenced by another book. Failed commits keep the files intact.
- Validate PDF page targets and reader events; support UTF-16 chapters and
  namespaced or implicit XHTML heads.
- Open the previous chapter at its last page. Return to the current reading
  marker with Shift+M, including markers in another chapter.
- Keep PDF zoom consistent across page navigation and follow system-theme changes.
- Flush note drafts before export. Serialize media changes with text saves;
  update attachment link labels after renaming and open existing reminder links.
- Respect saved sketch paths and prevent stale drawing windows from resurrecting
  removed attachments.
- Scope recording playback controls and pending starts to their owning attachment;
  retain seek positions while paused and ignore stale polls.
- Focus range controls explicitly so their keyboard arrows adjust the control
  instead of paging the book; this preserves the current control styling.
- Apply narration voice/speed changes to the current passage, preserve pause and
  source time, and seek across chapter passages.
- Restore saved sort direction and tolerate damaged local preference values.
- Display native open/import/recovery errors in the existing error banner.
- Configure the local desktop build with the existing installed-app Google client
  inputs. Mocked requests cover code exchange and refresh; no Drive consent or
  account data is changed by these checks.

Live Mac checks so far passed library search, grid/list switching, rename,
EPUB Unicode note persistence, reminder creation/completion/reopening and return
to source. The PDF fixture passed import, outlines, rotation/crop rendering,
selection, highlight/note creation and restoration to page 3 after reopening.
The November 12 review build also opened an existing reminder from its Markdown
preview link and retained the saved reminder when the dialog was cancelled.
Offline narration advanced through the fixture, accepted pause/resume, retained
pause when changing to 1.5x speed, and skipped across passages. The corrected
narration range retained keyboard focus and arrow input without paging the book.
A synthetic Ask AI question completed, used one credit and persisted both messages.

The live backward-chapter check exposed a second asynchronous reflow restoring
the chapter start. The copied runtime now preserves chapter-end intent until
layout completes; actual-runtime regressions and the full 113-test frontend suite
pass. The final November 12 live check passed: Previous from chapter 2 page 1
opened chapter 1 at page 2 of 2.

The November 12 Library follow-up passed 113 frontend and 122 Rust tests, the
frontend/native app build, formatting and strict Clippy. The final live build
closed the previous book menu when another opened, dismissed with Escape, and
activated Remove/Rename without a descendant focus change swallowing the click.
Cancelling Rename left every menu closed. Removing the PDF fixture with reading
data retained changed the Library count from four to three. Reimport restored
four documents, page 3 and the existing cropped-page note. No reading data was
permanently deleted. Removal also invalidates pending opens so an older download
cannot restore a hidden card.

The first full Apple-boundary check passed all 288 starting files. A later check
reported a concurrent edit to `App/AI/AIChatService.swift`; desktop work left it
and the protection baseline unchanged. Its hash stayed stable during the final
verification. The other 287 protected files still match the recorded baseline.

Device-denial/removal checks, live Google Drive round trips, and native
Windows/Linux acceptance must still be recorded separately. A Mac
development-host pass does not establish those release gates.
