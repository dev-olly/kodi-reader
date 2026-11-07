# Audio reader implementation plan

Status: Proposed. Research checked on 26 October 2026. Implementation has not started.

## Recommendation

Add a native **Listen** feature with ElevenLabs narration, starting with EPUBs. Users can listen from their current passage, pause, change speed, and return later to the same spoken position. Keep generated audio on the Mac so replaying it does not require another provider request.

Use `eleven_flash_v2_5` as the initial integration baseline. Compare it with Multilingual v2 and the current flagship Eleven v4 before choosing the release voice and model. Ship continuous EPUB playback first, then text PDFs and finer text following. Use the existing authenticated Kodi backend for the public product, with a separate audio allowance and a server-held ElevenLabs key.

## First release experience

- A **Listen** toolbar button starts at the current visible passage or resumes the saved listening position.
- **Read Aloud** in the selection actions speaks only that selection and stops at its end. Keep these actions usable in the existing compact palette.
- A compact native player shows play/pause, previous/next passage, voice, playback speed, chapter, and buffering/error state. Previous/next passage is sufficient for the first release; time-based seeking can follow.
- Offer a small curated voice list. Previewing a voice uses a reusable sample rather than regenerating the user's passage.
- Continue across EPUB chapters. Save the listening position when pausing, changing documents, and quitting; reopening a book never starts sound automatically.
- Provide **Follow Text** and **Return to Audio**. Browsing elsewhere while listening should work. A transient paragraph cue identifies the spoken passage without creating or changing saved highlights.
- Explain on first cloud use that the passages being narrated are sent to ElevenLabs. Send the playing segment and at most one upcoming segment, rather than uploading the book.

Defer whole-book audio export, automatic full-book generation, custom voice cloning, OCR, cross-device audio sync, and the iOS port. Saved webpages already imported as EPUBs can use the EPUB path once verified; live browser pages are outside the first release.

## ElevenLabs findings

### Models and endpoints

Flash v2.5 offers a documented 40,000-character request limit. Multilingual v2 has a 10,000-character limit and is documented as the most stable option for long-form generations. The current v4 model supports 90+ languages and is available through Text to Dialogue; v4 Turbo is documented through the Text to Dialogue WebSocket. These endpoints are not interchangeable with the older TTS API. Our much smaller narration segments should stay comfortably below provider limits. [Models](https://elevenlabs.io/docs/overview/models)

For Flash and Multilingual v2, prototype `POST /v1/text-to-speech/{voice_id}/with-timestamps`. It returns audio plus character timing for both original and normalized text. Completed MP3 segments provide a straightforward first playback/cache implementation. [Create speech with timing](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps/)

If waiting for a complete segment misses the startup target, evaluate `/stream/with-timestamps`. Its response contains JSON messages with base64 audio and alignment, so it needs an incremental parser and audio pipeline; it cannot simply be given to a player as an MP3 URL. Test PCM buffering with `AVAudioEngine` against completed MP3 segment playback before committing to that extra complexity. Supply adjacent text where supported to improve continuity. [Stream speech with timing](https://elevenlabs.io/docs/api-reference/text-to-speech/stream-with-timestamps/)

Compare v4 through its own timestamp-capable dialogue endpoint, with one narrator voice. Verify the actual model/voice combination and timing behavior in the spike. Do not assume a model change is just a different `model_id` on the existing TTS route. [Dialogue timing](https://elevenlabs.io/docs/api-reference/text-to-dialogue/convert-with-timestamps)

The published Flash inference figure is not a promise of instant playback: request routing, generation, decoding, and player buffering all affect time to first audible speech. Measure the complete path from this Mac through the Kodi proxy. [Understanding latency](https://elevenlabs.io/docs/eleven-api/concepts/latency)

### Cost and funding

Current published API rates are $0.04 per 1,000 characters for Flash/Turbo and v4 Turbo, and $0.08 for Multilingual v2 and v4. **Calculated example:** 100,000 words at an assumed six characters per word, including spaces, gives 600,000 characters: approximately **$24 or $48 for one complete new generation**. These estimates exclude retries, any voice-specific modifiers, taxes, and Kodi hosting. Actual subscription allowances and account terms affect the invoice. [API pricing](https://elevenlabs.io/pricing/api)

Use a capped internal allowance during development. For public release, meter generated characters separately from Ask AI answers and present a clear listening allowance. Existing approved chat pricing defines one credit as one answer; it does not authorize audio billing. Cached replay and local playback-speed changes should make no generation request. A user-supplied ElevenLabs key is an alternative for a private beta if avoiding hosted generation costs is more important than setup simplicity.

### Data handling

Disable the provider account's model-training data use before sending reader content. Self-serve paid accounts should not be assumed to have training disabled. [Data-use controls](https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models)

Default provider retention exists. Zero Retention Mode is available to select Enterprise customers, so ordinary accounts cannot promise it. Update Kodi's privacy text to describe the actual provider configuration; keep book text and audio out of application and proxy logs. [Retention](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode)

Public release needs an appropriate commercial plan and eligible voices/models. Provider output licensing does not supply rights to redistribute the underlying book; audio export is deferred. [Commercial-use guidance](https://elevenlabs.io/docs/help-center/legal/can-i-publish-the-content-i-generate-on-the-platform)

## Fit with the current code

`Sources/ReaderUI/Resources/reader.js` already contains readable-node traversal, block grouping, and DOM locator helpers. Its existing surrounding-passage API is capped at 2,400 characters and discards detailed source mapping. Build a dedicated narration extractor rather than using that AI-context API as a book reader.

`ReaderController` already exposes selections, viewport position callbacks, and navigation to a `Locator`. `App/ReaderScreen.swift` and `App/AnnotationViews.swift` provide the native toolbar, reading surface, and passage actions. `Sources/EpubKit/PDFBook.swift` exposes PDFKit text and extraction permissions.

The macOS app already has authenticated request and cancellation patterns in `App/AI/AIChatService.swift` and Keychain-backed sessions in `AIAuthController`. The proxy source is in the adjacent `../kodi-reader-ai` repository, not the website API folder. Its chat limiter and optional answer-credit ledger need dedicated audio policies. Payment UI is currently feature-gated; this plan does not assume audio funding is already live.

## Proposed components

### Ordered speech source

Introduce `SpeechSegment` and EPUB/PDF speech-source interfaces. Each segment contains a stable ID, exact submitted text, source locator ranges, source-text fingerprint, language hint, and mappings from spoken-text offsets back to original source offsets.

Start with sentence groups of roughly 400–1,200 characters, allowing smaller opening segments. Treat these as tuning values. Preserve paragraphs and punctuation; skip scripts, navigation, hidden content, and reader overlays. Avoid reading footnote bodies twice. Handle Unicode, soft hyphens, inline formatting, and numbers without losing locator mappings.

Only one chapter is mounted in the visible reader. Use a separate narration chapter context, preferably a dedicated nonpersistent WebKit view sharing the EPUB scheme handler and extraction helpers, to prepare following chapters without turning the visible page. Sequence chapters through `Publication.readingOrder`. Give this context its own lifecycle and recovery after load failures or WebContent process termination. Verify its DOM paths against the displayed chapter. Do not start narration-source loads through the visible `ReaderController` or publish their position events as reading progress.

### Native controller and playback

Add `App/Audio/ReadAloudController.swift`, a provider-client interface, a segment player, and a compact player view. Own one active document/session and explicit loading, buffering, playing, paused, ended, and failed states.

For completed MP3 segments, evaluate `AVQueuePlayer` with prepared local files. Measure boundaries and encoder padding; do not assume file queuing guarantees seamless speech. Use the streaming alternative only if the spike demonstrates a material benefit. Apply speed locally so changing it does not regenerate speech. [AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer)

Keep the audio cursor independent from the viewport cursor. Persist book ID, segment/source identity, locator, media offset, and voice/model settings in a separate local state file initially. Restore only when the source fingerprint matches. A transient spoken-text layer should redraw after typography changes without entering the annotation store. Missing or mismatched timing should fall back to paragraph following.

### Local cache

Store completed audio and alignment outside `library.json`, scoped to the local profile and book. Key entries by source text, extraction version, voice, model, provider generation settings, and output format. Playback speed is not a generation setting.

Use atomic completion, bounded disk storage, eviction, and a **Clear Downloaded Audio** control. Pin currently playing files. Never treat incomplete files as reusable. Prefetch at most one segment, with a bounded generation budget. Cached material can play offline; a cache miss should pause with a clear status. Rebuilding a missing segment may incur generation cost.

### Hosted delivery and metering

Add proposed routes such as `GET /v1/audio/voices` and `POST /v1/audio/segments` to the adjacent backend. Reuse authenticated user identity, but enforce server-selected models, curated voices, text limits, character budgets, and audio-specific concurrency. The provider key remains on the server. [ElevenAPI application and credential terms](https://elevenlabs.io/elevenapi-terms)

Bind each request UUID to the authenticated account and a request fingerprint. Persist in-flight/completed/uncertain status so reconnects do not silently start a second generation. Provider request IDs support continuity; they are not a substitute for Kodi's duplicate protection. Define a short-lived, authenticated result-recovery policy before enabling automatic retries; a timeout after provider acceptance may already have incurred cost.

Cancellation should stop queued playback and prefetch promptly, but cannot promise to reverse provider charges. Book changes and sign-out invalidate the session so late responses cannot start old audio. Record operational counts, characters, latency, and estimated cost without logging passages.

## Implementation sequence

1. **Provider and playback spike.** Use a small public-domain fixture to compare Flash, Multilingual v2, and v4. Measure audible startup, voice quality, timestamp mapping, paragraph boundaries, cancellation, cache replay, and provider usage. Exit with one supported model/voice/format combination and a playback approach. No paid provider test was performed during this research.
2. **Extraction and position foundation.** Implement deterministic EPUB segments, source mappings, separate chapter preparation, and independent audio progress. Exit when extraction covers a full book without omissions or duplicates and browsing does not move the audio cursor.
3. **EPUB listening release.** Add Listen, selection playback, compact controls, continuous chapters, voice/speed settings, paragraph following, resume, local cache, and one-segment prefetch. Exit when a long session and app relaunch work reliably.
4. **Hosted release hardening.** Add dedicated entitlement/metering, duplicate-request recovery, privacy settings/text, budget limits, and operational monitoring. This is required before a public cloud-audio release, even if developed alongside phase 3.
5. **Formats and polish.** Add extractable text PDFs with page ranges, then finer timed following, media keys/Now Playing, a sleep timer, and explicit chapter downloads. Respect PDF extraction permissions and identify scans; defer OCR and difficult multi-column reading-order reconstruction. Consider Apple system speech as a separate low-cost/local option after the ElevenLabs path works.

## Acceptance checks

- Extraction handles inline emphasis, hidden text, headings, lists, paragraph breaks, footnotes, and Unicode. Source mappings survive reflow and font changes.
- Selection playback stops at the selection boundary. Full narration continues at chapter boundaries without repeating or skipping sentences.
- Pause/resume, speed changes, backward navigation, document switches, sign-out, and relaunch cannot leave stale sound or overwrite visual reading progress.
- Saved highlights and notes remain unchanged; spoken cues are transient and distinguishable.
- Replaying cached speech makes zero provider requests. Voice/model/text changes invalidate the right entries. Interrupted downloads never become cache hits.
- Test 401, 429, quota exhaustion, stream truncation, disconnects, timeouts after provider acceptance, and duplicate request UUIDs. Verify allowance settlement and recovery under each outcome.
- Test a sustained listening session with bounded memory/disk use and a slow connection. Set a provisional audible-start target of three seconds on the reference connection, then revise it from measured results; provider inference figures are not acceptance results.
- For PDFs, cover extraction-denied documents, image-only scans, Unicode ranges, page transitions, and a representative multi-column document before claiming support.

## Decisions before public release

Choose the narrator/model after the spike, the supported initial languages, the funded audio allowance and retail pricing, the provider privacy configuration, and the cache size limit. Recommended starting scope is macOS EPUB narration with a capped hosted beta, local progress/cache, and paragraph following.
