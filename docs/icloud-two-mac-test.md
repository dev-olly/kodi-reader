# Test iCloud sync on two Macs

Apple Developer setup, signing profiles and the Production schema are ready.
Use `.build/releases/KodiReader-iCloud-test.dmg` on both Macs. This test build
supports Apple Silicon and macOS 15 or later. Both Macs must use the same
personal iCloud account; neither needs an Apple Developer login.

## Main acceptance test

1. Install the DMG on both Macs. Open **Kodi Reader → Settings → Sync** and choose **iCloud**.
   Sync starts Off. Use a disposable EPUB or PDF for this test.
2. Choose **Notes only** on both Macs. Import the same exact file on each,
   even with different filenames. On Mac A add a note, drawing and bookmark,
   then move to another page. Use **Sync Now** on each Mac. Check that Mac B
   receives the changes and reopens at the saved position. Edit a note on B
   and verify it reaches A. An already open reader should keep its viewport.
3. Choose **Books and notes** on A and import another test book that is absent
   from B. Keep B on **Notes only**. Its Home should show the cloud book without
   downloading its file. Switch B to **Books and notes**, open it and confirm
   the download succeeds. Also try **Download for Offline Reading**.
4. Save an Ask AI conversation on A. Enable **Sync Ask AI history** on A while
   leaving it off on B. B must not receive the conversation. Enable it on B
   and verify the saved conversation arrives. Unsent drafts stay local.
5. Disconnect both Macs from the network and edit the same test note differently.
   Reconnect A and let it sync, then reconnect B. Both edits should survive,
   with one labeled **Recovered version**. Repeated Sync Now and app restarts
   must not create duplicate recovery copies.
6. On B choose **Remove Download**. The book's notes and Home entry must remain.
   Reopen/download it, then read it offline. **Remove from Recent** only hides
   the entry on that Mac.
7. Using only the disposable test book, confirm **Delete Book and Notes Everywhere**
   on A. After B reconnects/syncs, the book and notes must disappear there too.
8. Repeat a small note change with both apps open, without pressing Sync Now.
   Verify automatic delivery. Also edit while B has a note/drawing editor open;
   saving/closing it must preserve local work and then merge the remote edit.
   A streamed AI reply must finish normally during a remote change.

For each step, Settings should eventually show **Synced** and a recent successful
sync time. Offline edits remain readable; reconnecting should clear the offline
status. If a step fails, record the two modes, AI toggles, status/error, and which
Mac made the edit. Avoid sharing note, book or conversation contents in logs.

## Release gate

The automated tests and one-Mac Development integration test pass. The DMG is
Developer ID signed, notarized and stapled. The checklist above is still pending:
it validates the real reader, Production database, cross-device notifications
and per-Mac preferences. Keep this build for testing until those checks pass.

Additional live release checks remain: no iCloud account, sign-out/account switch,
cloud data cleared outside Kodi, real quota exhaustion, and interrupted transfers
in the reader. The deterministic suite covers the corresponding data-loss and
retry behavior, but it cannot validate Apple's live account, quota or push service.
