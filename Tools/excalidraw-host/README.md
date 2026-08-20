# Excalidraw host

Offline drawing UI bundled into Kodi Reader. npm is a **build-time** tool; the
app itself does not depend on Node.

```sh
cd Tools/excalidraw-host
npm ci
npm run build
```

That writes static assets into `Sources/ReaderUI/Resources/Excalidraw/`, which
the reader scheme handler serves from `Bundle.module`. Rebuild after changing
the host source and commit the generated files so the app stays buildable
without Node.
