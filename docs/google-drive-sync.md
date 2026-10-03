# Google Drive sync

Kodi Reader can sync through the Google account you connect in **Settings → Sync**.
It asks for separate permission to its hidden Google Drive app-data folder; Ask AI
sign-in does not grant Drive access. The folder uses your Google storage allowance.
Google Drive sync requires a build with Kodi's desktop OAuth client configured.

Select **Google Drive**, then choose **Notes only** or **Books and notes**. Notes
only transfers book details, highlights, notes, drawings, bookmarks, and reading
position. Import or locate the same book file on each Mac. Books and notes also
transfers imported EPUBs, PDFs, and saved webpages. A cloud book appears in the
library before its file downloads; open it or choose **Download for Offline
Reading** to fetch the file. **Sync Ask AI history** separately includes saved
conversations and passage references when enabled. Drafts, credentials, credits,
and AI settings stay local.

Your Mac can have only one active provider. Switching between iCloud and Google
Drive asks you to confirm a one-time copy of the local library, after fetching
the current provider's latest changes. For Books and notes, locate or download
missing book files before copying. The prior cloud copy stays in that account;
switching does not bridge changes between the two clouds afterward. Each Mac can
choose its provider and content mode independently.

Settings shows the connected Google account, sync status, last successful sync,
and **Sync Now**. Kodi checks Drive on launch, foregrounding, Sync Now, and every
five minutes while active. It sends notes after two seconds of idle time and
reading position at most every thirty seconds. The local library remains usable
offline; pending changes resume when Drive becomes available. Concurrent note
text, drawing, and Ask AI edits retain labeled **Recovered version** copies.

**Remove from Recent** hides a book on this Mac. **Remove Download** keeps its
notes and cloud copy. **Delete Book and Notes Everywhere** places a tombstone
in the active provider; the other cloud's older copy remains. Google Drive keeps
immutable revision data and attached chunks to support recovery from a long-
offline device. If you need to erase all historical Kodi cloud data, remove
Kodi Reader's app-data folder from the Google account and re-enable sync
explicitly afterward. Kodi pauses rather than silently republishing a known
deleted cloud copy.

If you change Google accounts, Kodi pauses sync and requires explicit
re-enablement before copying this Mac's local library to the new account. It
does not delete the previous account's data or local files. **Disconnect Google
Drive** removes Kodi's local Drive token and turns off Drive sync without
deleting the local or cloud library. See
[Google Drive setup and testing](google-drive-sync-setup.md) for build setup.
