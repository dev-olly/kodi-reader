# Kodi Reader desktop third-party notices

Kodi Reader's application source is MIT licensed. Dependency licenses apply to
their respective components. The Rust and npm lockfiles identify the exact
dependency versions used in a candidate build. Existing Apple-only dependencies
are described in the repository's original `NOTICE.md`.

Distribution builds run `scripts/collect-notices.mjs` to copy the license texts
supplied by the resolved Cargo and npm dependencies into bundled `licenses/`
resources, together with an inventory of their declared SPDX license expressions.

## Desktop application and reader

- Tauri, Tao and Wry: MIT/Apache-2.0; https://github.com/tauri-apps/tauri,
  https://github.com/tauri-apps/tao, https://github.com/tauri-apps/wry.
- React and React DOM: MIT; https://github.com/facebook/react.
- CodeMirror packages: MIT; https://github.com/codemirror.
- Lucide: ISC; https://github.com/lucide-icons/lucide.
- PDF.js: Apache-2.0; https://github.com/mozilla/pdf.js.
- Excalidraw: MIT; https://github.com/excalidraw/excalidraw. The offline editor is
  a pinned copy of the repository's existing host; its bundled fonts and other
  third-party components retain their original licenses and attribution.
- quick-xml, zip-rs, lopdf and pulldown-cmark: MIT;
  https://github.com/tafia/quick-xml, https://github.com/zip-rs/zip2,
  https://github.com/J-F-Liu/lopdf, https://github.com/pulldown-cmark/pulldown-cmark.
- Serde, Tokio, reqwest, RustCrypto, UUID, tempfile, CPAL, keyring and their
  transitive dependencies retain the licenses declared in their manifests and
  bundled license files. Cargo.lock fixes the versions used by the build.

## FFmpeg

This software uses a separate executable from the FFmpeg project under the GNU
Lesser General Public License, version 2.1 or later:
https://ffmpeg.org/ and https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
Kodi invokes this executable as a separate process for local audio conversion.

The minimal audio-only build disables GPL, version-3 and nonfree components,
external autodetection and network access. Each built distribution includes the
unmodified, corresponding FFmpeg source archive, source signature, license,
SHA256 and exact build configuration under its `ffmpeg/` resources. The signed
release also carries these corresponding sources beside its installers. Users
can rebuild the executable with `scripts/build-ffmpeg.sh` and select a compatible
replacement through `KODI_FFMPEG_PATH`.

The pinned source version is 9.0.2, SHA256
`8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
The builder verifies FFmpeg's PGP release signature against fingerprint
`FCF986EA15E6E293A5644F10B4322F04D67658D8`.

## Local speech runtime and optional model downloads

- sherpa-onnx: Apache-2.0; https://github.com/k2-fsa/sherpa-onnx.
- ONNX Runtime: MIT; https://github.com/microsoft/onnxruntime. It is used by the
  local speech runtime; its own third-party notices apply.
- Pocket TTS by Kyutai: CC-BY-4.0 model attribution;
  https://huggingface.co/kyutai/pocket-tts. The exact ONNX conversion source,
  pinned revision, model sizes/hashes and included license are recorded in
  `src-tauri/crates/desktop-services/src/model-catalog.json`.
- Whisper by OpenAI: MIT; https://github.com/openai/whisper. The catalog records
  the pinned ONNX model revision and checksums used for local transcription.
- VCTK reference recordings: CC-BY-4.0; University of Edinburgh, with enhanced
  references distributed by Kyutai at https://huggingface.co/kyutai/tts-voices.
  Voice labels map to VCTK speakers Anna/p228, Azelma/p303, Charles/p254 and
  George/p315. The catalog identifies the exact recordings, source revision,
  license download and hashes.

Model and voice downloads are optional and are not part of the application
source license. Their original license/attribution continues to apply to the
downloaded files. Refer to the pinned catalog and upstream license for each
component's complete terms.
