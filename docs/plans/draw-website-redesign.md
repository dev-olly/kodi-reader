# Draw: Website-Inspired Workspace

Status: Approved design; implementation not started by this handoff.
Audience: GPT-5.5 or the engineer implementing this plan.

## Objective

Bring the website's Draw preview into the native Kodi Reader app: a white dotted canvas, crisp forest-green strokes, pale-green and pale-yellow shapes, understated connectors, and a quiet toolbar. Retain Excalidraw as the editing engine and preserve existing drawings.

This is a functional editor redesign, not an image replacement. The website preview is an SVG illustration with a simple freehand canvas on top; it is a visual reference, not reusable editor logic.

## Approved Decisions

- Simple tools first, with an Advanced tools toggle exposing the full existing editor.
- One mounted editor and one scene across both modes, workspace resizing, and expansion.
- New drawings start blank. An optional Connection template creates editable elements inspired by the website.
- Supported sans-serif text inside the canvas. Serif typography remains in the surrounding native passage header. Do not add a custom-font fork or replace existing font mappings.
- No automatic sample content, destructive replacement, or restyling of existing drawings.
- Local app and DMG delivery only. No GitHub publication, commits, or pushes unless separately requested.

## Read Before Editing

The repository has uncommitted app and website changes. Start with `git status --short` and inspect relevant diffs. Preserve all existing changes and work with the current code, not an earlier version described in chat.

Primary references and integration points:

- `website/index.html`: `.draw-preview`, `.sketch-stage`, and the editable-preview illustration.
- `website/styles.css`: drawing colors, dotted background, spacing, and controls.
- `website/showcase.js`: demonstration-only freehand behavior; do not use it as the app's drawing engine.
- `Tools/excalidraw-host/src/main.jsx`, `src/host.css`, and `public/kodi-theme.css`: React editor host and source styles.
- `Tools/excalidraw-host/package.json`: pinned Excalidraw 0.18.0 and Vite build command.
- `Tools/excalidraw-host/vite.config.js`: generated output goes to `Sources/ReaderUI/Resources/Excalidraw`; output is emptied on rebuild.
- `Sources/ReaderUI/ExcalidrawController.swift`: WKWebView lifecycle, scene bridge, theme, and callbacks.
- `App/NoteEditor.swift`: drawing mode, autosave, scene loading, and teardown.
- `App/ReaderScreen.swift`: shared workspace and expansion behavior.
- `App/AppModel.swift` and existing drawing storage: persistence and annotation association.

Read applicable repository instructions before edits. Do not modify the website as part of this task. Treat this file as the approved specification; keep progress and verification notes separately.

## Design Specification

### Canvas and Elements

- White light-mode canvas with a subtle dotted background. Use existing charcoal-green theme surfaces in dark mode.
- Default stroke: forest green `#245744`; secondary connector green `#648676`.
- Offer pale-green `#E1EDDB` and pale-yellow `#FFF2C1` fills, transparent fill, and readable dark ink.
- New shapes use clean strokes with zero sketch roughness and solid fills; use modest rounded corners where supported.
- Use supported sans-serif canvas labels. Preserve the original styling of every loaded element.
- Render dots as a non-interactive decoration aligned with scene coordinates during pan and zoom. Dots must not become stored scene elements or intercept input. Respect explicitly stored canvas backgrounds.

### Simple Toolbar

- Primary tools: selection, hand/pan, freehand pen, rectangle, ellipse, connector, and text.
- Controls: color swatches, stroke widths 1/2/4, solid or transparent fill, undo, redo, zoom out/in, fit to content, and Advanced tools.
- Prefer existing Excalidraw icon assets or an existing icon library. Use fixed-size icon buttons with accessible names, tooltips, keyboard focus, and visible active states.
- Provide a numeric zoom readout. Keep important tools visible; move secondary controls into an overflow menu at narrow widths.
- Do not remove advanced-only scene elements when Simple mode is active. They remain visible and selectable; Advanced provides their full editing controls.
- No decorative sample instructions inside the canvas.

### Surrounding Workspace

- Keep chapter context and a compact serif passage header above the drawing. Collapse the long quote in Draw mode, with an accessible control to reveal it.
- Keep a quiet save-status footer. Show saving, saved, and failure states based on actual persistence, not a timer-only label.
- Provide explicit expand/collapse controls using the existing shared workspace behavior. Preserve the reading locator before layout changes.
- Switching Simple/Advanced, Notes/Ask AI, or expanded/collapsed presentation must preserve live content, selection, viewport, and undo history.
- Inactive drawing surfaces must not intercept reader keyboard shortcuts or pointer events.

### Connection Template

- Available explicitly when the canvas contains no live elements; never automatically inserted.
- Create two editable boxes labeled "attention" and "noticing", using green and yellow fills, plus native editable connectors and the label "a new perspective".
- Use the website composition as a reference, not a raster or SVG pasted into the scene.
- Insert all elements as one undoable operation, with valid unique IDs and connector/text bindings. Fit the inserted composition to the viewport.
- Never clear or overwrite existing drawing data to insert a template.

## Engineering Requirements

1. Build the Simple controls in the existing React host. Keep the Excalidraw instance mounted and use supported tool/scene APIs; Advanced reveals the original UI around that same instance.
2. Inspect local Excalidraw declarations and implementation before calling APIs. In 0.18.0, the imperative history object exposes `clear`, not public `undo()` or `redo()` methods. Reuse supported native actions or existing history controls. Do not invent APIs, maintain a separate undo stack, or use broad document-level keyboard simulation as a substitute.
3. Encapsulate any necessary version-specific UI styling in the host stylesheet. Prefer supported UI customization to brittle DOM selectors; verify any selectors against the pinned version.
4. Apply Kodi defaults only when initializing a genuinely new scene or creating new elements. Opening an older scene must not rewrite its fonts, backgrounds, colors, identifiers, bindings, or images.
5. Keep one authoritative live scene. Audit `handleModeChange`, pending-scene loading, and teardown so returning to Draw cannot reload stale `drawingScene` props over recent edits.
6. Preserve the existing Excalidraw scene format and annotation association. Keep assets and IDs intact. Preserve undo/deleted-element state during the live editing session; do not serialize UI-mode transitions as content edits.
7. Flush the live scene before teardown or changing the edited annotation. Retain the live drawing if persistence fails and expose a retry path. Do not report Saved until the storage operation confirms success; extend internal completion/error callbacks if necessary.
8. Extend the internal Swift/JavaScript bridge only where needed for presentation, lifecycle, or save status. Use structured JSON serialization rather than interpolating unescaped user text into scripts. No public service or backend API changes.
9. Rebuild drawing resources from source. Because Vite empties its output directory, all necessary custom styles/assets must originate in source or `public/`, not only in generated resources. Preserve the existing classic-script/IIFE packaging required by the WKWebView host.
10. Avoid dependency upgrades, unrelated refactors, reader restyling, and changes to the website. Do not migrate existing book data for this redesign.

## Implementation Sequence

1. Inspect current changes, host APIs, drawing lifecycle, and persistence. Record any concrete incompatibility before modifying implementation.
2. Add the Simple/Advanced shell, theme-aware dotted canvas, and new-element defaults without changing existing scene loading.
3. Wire tool controls and native history actions; implement the optional editable Connection template.
4. Integrate compact native context, expansion controls, and truthful persistence status. Fix stale reload/lifecycle issues within the drawing flow.
5. Add focused tests, regenerate web assets, and build the native app.
6. Launch the packaged app, validate the scenarios below, capture screenshots, and deliver local artifacts with an honest verification report.

## Validation

- Draw and edit every Simple tool; verify swatches, fills, stroke widths, text editing, connectors, selection, pan, and zoom.
- Undo/redo normal edits and template insertion. Switching tool modes must not clear history or alter content.
- Verify dots stay aligned during pan/zoom, remain sharp at Retina scale, do not affect hit testing, and do not enter exported scene data.
- Open a pre-existing scene containing text, shapes, connectors, and images. Save/reopen it without visual or data loss.
- Rapidly switch Draw/Edit/Preview and Notes/Ask AI; resize, expand, collapse, close, and reopen. Confirm recent edits and reading position survive.
- Exercise delayed save, failure, retry, and teardown. Confirm the latest scene is persisted, not an older prop snapshot.
- Verify light/dark mode at 640x480, 1100x820, and a wide desktop size. No overlapping controls, inaccessible canvas, clipped labels, or toolbar-driven layout shifts.
- Check keyboard tools, focus return, VoiceOver labels, and reduced motion. Drawing shortcuts must not turn book pages while the canvas is focused.
- Keep tests deterministic and offline. Do not modify personal drawings for destructive tests; use dedicated review fixtures.

## Build and Review Commands

Use Xcode 26.3 explicitly on this machine:

```bash
npm --prefix Tools/excalidraw-host run build
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild -project KodiReader.xcodeproj -scheme KodiReader -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer ./Scripts/package-dmg.sh
open "/Users/olly/Documents/Projects/epub-reader/.build/dmg/Kodi Reader.app"
```

Use the existing dependency lockfile/install workflow if dependencies are unavailable. Do not silently update versions. Request necessary build/cache permissions through the normal tooling.

The package script checks framework dependencies. Preserve that verification. A build success is not launch verification. Quit the previous review copy before launching the new packaged app, and verify the actual running surface is the updated build.

## Deliverables and Completion Criteria

- Working local packaged app at `.build/dmg/Kodi Reader.app` and updated `KodiReader.dmg`.
- Screenshots in `.build/design-review/` covering blank Simple canvas, Connection template, Advanced tools, dark mode, and a narrow window.
- A separate verification note listing commands/results, manual scenarios checked, and any outstanding limitations. Previous work reported 118 passing tests; rerun rather than assuming that result still holds.
- Final response links to the app/DMG and screenshots and states any unverified acceptance checks. Do not claim full completion based solely on compilation.
- No release publication, commit, push, or edits to the website without separate authorization.
