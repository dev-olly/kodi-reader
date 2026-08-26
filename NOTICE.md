# Third-party notices

Kodi Reader includes or depends on the following projects. Their licenses
apply to those components; this file is not a substitute for the copies
shipped with each dependency.

## ZIPFoundation

- Source: https://github.com/weichsel/ZIPFoundation
- License: MIT
- Used by EpubKit to read EPUB ZIP containers.

## Excalidraw, React, and React DOM

- Source: https://github.com/excalidraw/excalidraw (`@excalidraw/excalidraw` 0.18.0)
- License: MIT
- Bundled as a static offline host under `Sources/ReaderUI/Resources/Excalidraw/`.
  Rebuilt from `Tools/excalidraw-host/`. React and react-dom (MIT) ship in that
  bundle as well.

## mlx-swift

- Source: https://github.com/ml-explore/mlx-swift
- License: MIT
- Apple Silicon tensor runtime used by on-device read-aloud.

## KokoroSwift (kokoro-ios)

- Source: https://github.com/mlalma/kokoro-ios
- License: MIT
- Swift wrapper that drives Kokoro TTS on MLX.

## MLXUtilsLibrary

- Source: https://github.com/mlalma/MLXUtilsLibrary
- License: Apache License 2.0
- Helper library required by KokoroSwift.

## Kokoro TTS model weights

- Source: https://huggingface.co/hexgrad/Kokoro-82M
- License: Apache License 2.0
- Not vendored in this repository. The first read-aloud session downloads the
  weights (and a voice pack) into Application Support. Apache-2.0 requires
  that attribution be preserved; this notice is that attribution.
