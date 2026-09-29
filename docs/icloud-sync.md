# iCloud sync

Kodi Reader can sync through the iCloud account signed into your Mac. This
requires an iCloud-enabled, Apple-signed Kodi build. It uses your personal iCloud
storage; no Kodi account or separate sync subscription is needed.

Open **Settings → iCloud** and choose:

- **Off**: the default. Read and edit locally.
- **Notes only**: sync book titles and authors, highlights, attached notes and
  drawings, bookmarks, and reading position. Import or locate the same file on
  each Mac. A different edition will have a separate identity.
- **Books and notes**: additionally upload imported EPUBs, PDFs, and saved
  webpages. The library appears on other Macs before the book files download.

**Sync Ask AI history** is independently off by default. Enable it with either
sync mode to include saved conversations and passage references. Unsent drafts,
AI configuration, credentials, and credit balances are excluded.

Choose different modes on different Macs. Switching modes or turning off AI
history stops transfers in the disabled category and keeps existing copies.

## Downloads and removal

Books and notes downloads a cloud book when you open it. Right-click a book and
choose **Download for Offline Reading** to download ahead of time. Download
progress appears on the book. Once downloaded, it works without a connection.
Notes only shows cloud books and lets you locate or import a matching file.

**Remove from Recent** hides a book only on this Mac. Settings has a button to
show hidden books again. **Remove Download** frees the installed book file while
keeping notes and cloud content. **Delete Book and Notes Everywhere** asks for
confirmation, then propagates deletion across Macs, including saved AI history.

Concurrent edits to the same note or drawing are retained as **Recovered
version** copies. Divergent AI histories become recovered conversations. If a
whole book is deleted while another Mac has unsynced edits, that Mac preserves a
local recovered library entry; it does not restore the deleted cloud book.

## Status and offline use

Settings shows the last successful sync and whether Kodi is synced, syncing,
offline, unable to use iCloud, out of iCloud storage, or needs attention. **Sync
Now** requests an immediate pass. Notes are batched after two seconds of idle
time; reading position is sent at most every thirty seconds. Closing a book or
backgrounding the app checkpoints local work.

Network and storage errors keep local edits queued for a later attempt. Sync
does not replace an open note or drawing editor, or interrupt an AI reply. Remote
reading positions apply when reopening the book without moving an active reader.

After an iCloud account change or removal of Kodi's iCloud data, sync pauses.
Enable it explicitly again and acknowledge uploading this Mac's local library
to the current account. Local files are preserved. Signing out of Kodi's Ask AI
account does not remove your reading library or iCloud copies.
