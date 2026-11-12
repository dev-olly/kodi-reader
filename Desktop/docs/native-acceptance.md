# Native acceptance for the Windows and Linux release

Every entry in `release-acceptance.json` starts pending. Record `passed: true`
only after running the applicable scenarios on the actual OS and saving evidence
for the exact candidate commit. Include the tester, date, OS/build, desktop
session, WebView runtime, installer SHA256, result, logs and screenshots or a
recording. Keep private book content, account tokens and email addresses out of
shared artifacts. CI smoke output is useful evidence for its stated checks; it
does not replace these scenarios.

## Supported release matrix

Exercise Windows 11 x64, Ubuntu 24.04 Wayland and X11, Ubuntu 26.04 Wayland and
Fedora Wayland. The automated Windows Server build is a build check; it is not
a Windows 11 acceptance pass. Test AppImage, DEB and RPM through their intended
installation and launch paths. An Xvfb run does not establish Wayland behavior.

For each system:

1. Install into a clean user account. Open EPUB/PDF from the app and from file
   association/double-click. Relaunch after closing all windows. Exercise paths
   with spaces, accents and emoji.
2. Import an EPUB 2/NCX book, EPUB 3/nav book, RTL book, image-heavy book and a large
   publication. Confirm covers, nested contents, internal links and footnotes.
   Reimport the same bytes under another filename; notes remain attached.
   Open action menus on successive books; only one stays open. Check outside
   click, Escape, keyboard focus and menu actions, including cancelling a dialog.
   Remove a disposable book with reading data retained: its card disappears and
   the Library count decreases, its notes remain, and reimport restores its data.
   Remote-only books remain visible. Remove during a delayed download/open and
   confirm the older operation cannot restore the removed card.
3. Read at narrow/wide sizes and 100%, 125%, 150% and 200% system scaling. Change
   fonts, text size, margins, line spacing, theme and two-page layout. Resize and
   toggle both sidebars while selecting text. The reader stays within its pane;
   text and popovers do not disappear behind another native child view.
4. Select passages spanning lines and inline markup, including emoji, ligatures,
   combining characters and RTL text. Add all highlight styles, edit a Markdown
   note and use undo. Close/reopen the book and restart the app. Restore the same
   passage after typography changes. Exercise keyboard shortcuts while focus is
   in the reader, note editor, settings and a modal.
5. Open PDFs with different CropBoxes, rotation, repeated quotations, multiple
   columns and multi-page selections. Confirm zoom, fit, highlights, notes,
   reminders, reading markers and navigation. PDF.js character indices must never
   be written as PDFKit indices. An unresolved anchor preserves its note and
   displays a useful state rather than attaching it to the wrong text.
6. Create/edit/delete/undo sketch references and audio references. Relaunch and
   confirm sidecar media and note links. Export all notes and one note to
   Markdown, Notion Markdown, HTML and DOCX. Open the output in an independent
   renderer; verify quotes, book/chapter metadata, drawings and playable audio
   links with their companion folder.
   Start a new note line with `/` and exercise sketch, audio and reminder actions
   through both the picker and Enter. Check aliases, failure/retry feedback and
   typing during a slow save. Examples inside fenced code must stay text; a retry
   must preserve the existing attachment ID. Empty notes need a normal line-height
   cursor, and native copy/paste/undo shortcuts must work in the focused editor.
7. Create, complete, edit and remove research reminders; navigate back to their
   passages. Remove a source note and confirm its reminder remains. Move the
   reading marker and return to it after relaunch.
8. Set a reading goal, earn a day and raise the goal. The earned day remains.
   Verify midnight transition, streak, inactive-window pause, idle pause and
   system sleep/resume. This works with usage analytics disabled.
9. Test malformed/truncated EPUB/PDF, archive path traversal, publisher scripts,
   external frames and links. Book content cannot call privileged commands,
   obtain credentials or read another document. Approve external navigation
   through trusted app controls. Existing imported originals stay unchanged.
10. Interrupt an import/save and simulate full disk or denied write access. The
    app reports the failure and keeps prior notes. Corrupt a copied test
    `library.json` to verify preserved-corrupt-file plus backup recovery; a newer
    unsupported schema must never be reset to empty.

## Google Drive and the existing Mac app

Use disposable test libraries and the existing Mac binary. Exercise Notes only
and Books and notes; opt AI history in separately. Confirm identical content
hash identity, on-demand download, offline edits/reconnect and sign-out/account
switch. Include highlights, marker, reminders, sketches, audio and multi-thread
chat. Concurrent note edits produce recoverable versions; delete versus edit
does not silently erase content. Interrupted media downloads must fail checksum
validation before replacing a good asset.

Round-trip Mac → Windows/Linux → Mac and Windows/Linux → Mac → Windows/Linux.
Compare both wire fixtures and what the user can actually see and edit. Existing
Mac PDFKit ranges must survive. Test newly created desktop PDF highlights on
the unmodified Mac app explicitly; local geometry or an unrenderable Mac note
does not count as a successful compatible round trip. Leave `macDriveRoundTrip`
pending while any supported data is lost, misanchored or uneditable.

## Account, privacy and local audio

Verify email-code sign-in, failed/expired code, session refresh after restart,
sign-out, account deletion and OS credential-store lock/unavailability. The
renderer never receives credentials. Exercise a real Ask AI streamed response,
cancellation, retry, offline failure and expired session. Book excerpts are sent
only through the configured explicit Ask AI flow. Test feature/payment flags in
their intended release setting and verify analytics opt-out.
Paste six- and eight-digit sign-in codes, including leading zeros and email-client
whitespace, using keyboard shortcuts and the native Edit menu. Pasting must not
submit automatically. Returning to a pending sign-in may restore its email for
ten minutes; the code itself must never be stored. Exercise the existing-code
entry path without requesting another email.

Install the verified speech models and voices. Disconnect networking, then record,
pause, resume, finish, play, seek, change speed, transcribe and narrate through a
chapter boundary. Test a denied microphone permission, disconnected input/output
device and a failed model download. Close a note or book during recording and
confirm the saved take. Use the actual built FFmpeg sidecar; a developer's PATH
codec is not release evidence. Store evidence under `offlineAudio`.

## Installer and signed update

Install candidate N, import books and add notes, then upgrade using a valid signed
N+1 update. Check the app, installer and updater artifact signatures; alter one
byte and verify update rejection. Interrupt download and installation, relaunch
and verify data retention. Test a dismissed update and package reinstall.
Uninstall/reinstall according to the documented data-preservation choice. Verify
the installed sidecar and bundled corresponding FFmpeg source/license/build
configuration. Record `signedUpdateUpgrade` and `installerDataRetention` only
after successful checks on Windows and each Linux distribution mechanism.

## Automated native smoke

With the app built, generate the offline fixture:

```sh
cargo run --manifest-path src-tauri/Cargo.toml --locked -p kodi-reader-core \
  --example smoke_fixture -- native-smoke.epub
cargo install tauri-driver --locked
dbus-run-session -- xvfb-run -a node scripts/native-smoke.mjs \
  src-tauri/target/release/kodi-reader-desktop native-smoke.epub
```

The smoke launches the actual app, imports through actual Rust IPC, checks its
publication, opens the child reader and saves a screenshot/result. On Windows,
install a Microsoft Edge WebDriver matching the installed WebView runtime and
run the same script with the `.exe` path. This harness does not auto-mark release
acceptance fields.
