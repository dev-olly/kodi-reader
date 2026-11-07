# Third-party notices

Kodi Reader includes or depends on the following projects. Their licenses
apply to those components; this file is not a substitute for the copies
shipped with each dependency.

## ZIPFoundation

- Source: https://github.com/weichsel/ZIPFoundation
- License: MIT
- Used by EpubKit to read EPUB ZIP containers.

## Sparkle

- Source: https://github.com/sparkle-project/Sparkle (2.10.0)
- License: MIT, with bundled third-party notices in Sparkle's LICENSE file.
- Provides signed in-app updates, installation, and relaunch on macOS.

## FluidAudio and Paradee

- Source: https://github.com/FluidInference/FluidAudio (0.18.2)
- Model: https://github.com/sahilmahendrakar/paradee (1.2, by Sahil Mahendrakar)
- Core ML conversion: https://huggingface.co/FluidInference/paradee-8m-coreml
- License: Apache 2.0. The license and FluidAudio's bundled dependency notices
  are included with the macOS app.
- Used for on-device English EPUB narration. Model and pronunciation files
  are downloaded on demand.

## Excalidraw, React, and React DOM

- Source: https://github.com/excalidraw/excalidraw (`@excalidraw/excalidraw` 0.18.0)
- License: MIT
- Bundled as a static offline host under `Sources/ReaderUI/Resources/Excalidraw/`.
  Rebuilt from `Tools/excalidraw-host/`. React and react-dom (MIT) ship in that
  bundle as well.
