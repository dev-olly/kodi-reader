#!/usr/bin/env bash
# Build the small, source-verifiable audio-only FFmpeg executable used by Kodi.
# The resulting codec has no GPL/nonfree components or network protocols.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=9.0.2
SOURCE_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
SIGNER=FCF986EA15E6E293A5644F10B4322F04D67658D8
TARGET="${1:-$(rustc -vV | sed -n 's/^host: //p')}"
BUILD_ROOT="${KODI_FFMPEG_BUILD_ROOT:-$DESKTOP_DIR/.cache/ffmpeg-$VERSION-$TARGET}"
RESOURCE_DIR="$DESKTOP_DIR/src-tauri/resources/ffmpeg"
BINARY_DIR="$DESKTOP_DIR/src-tauri/binaries"
ARCHIVE="$BUILD_ROOT/ffmpeg-$VERSION.tar.xz"
mkdir -p "$BUILD_ROOT" "$RESOURCE_DIR" "$BINARY_DIR"

for tool in curl tar make gpg gpgv; do
  command -v "$tool" >/dev/null || { echo "Missing FFmpeg build prerequisite: $tool" >&2; exit 1; }
done
checksum() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
download() { curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$1" --output "$2"; }
if [[ ! -f "$ARCHIVE" ]]; then download "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" "$ARCHIVE"; fi
[[ "$(checksum "$ARCHIVE")" == "$SOURCE_SHA256" ]] || { echo 'FFmpeg source checksum mismatch; refusing to build.' >&2; exit 1; }
download "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz.asc" "$ARCHIVE.asc"
download https://ffmpeg.org/ffmpeg-devel.asc "$BUILD_ROOT/release-key.asc"
bash "$SCRIPT_DIR/verify-source-signature.sh" "$ARCHIVE" "$ARCHIVE.asc" "$BUILD_ROOT/release-key.asc" "$SIGNER" > "$BUILD_ROOT/signature-status.txt"
bash "$SCRIPT_DIR/test-source-signature.sh" "$ARCHIVE" "$ARCHIVE.asc" "$BUILD_ROOT/release-key.asc" "$SIGNER"

SOURCE_DIR="$BUILD_ROOT/ffmpeg-$VERSION"
if [[ ! -d "$SOURCE_DIR" ]]; then tar -xJf "$ARCHIVE" -C "$BUILD_ROOT"; fi
CONFIGURE=(
  --disable-everything --disable-programs --enable-ffmpeg
  --disable-doc --disable-debug --disable-network --disable-autodetect
  --disable-gpl --disable-version3 --disable-nonfree --disable-shared --enable-static
  --disable-x86asm --disable-avdevice --disable-swscale
  --enable-protocol=file,pipe
  --enable-demuxer=mov,wav,pcm_f32le,pcm_s16le --enable-muxer=ipod,wav,pcm_f32le,pcm_s16le
  --enable-parser=aac --enable-decoder=aac,pcm_f32le,pcm_s16le
  --enable-encoder=aac,pcm_f32le,pcm_s16le
  --enable-filter=aresample,atempo,aformat,anull,abuffer,abuffersink,asetpts,atrim
)
EXTENSION=""
case "$TARGET" in
  x86_64-pc-windows-msvc|x86_64-pc-windows-gnu)
    CONFIGURE+=(--target-os=mingw32 --arch=x86_64 --cc=gcc --host-cc=gcc --extra-ldflags=-static)
    EXTENSION=.exe ;;
  x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu|aarch64-apple-darwin|x86_64-apple-darwin) ;;
  *) echo "Unsupported native FFmpeg build target: $TARGET" >&2; exit 1 ;;
esac
(
  cd "$SOURCE_DIR"
  ./configure "${CONFIGURE[@]}"
  make -j "${KODI_BUILD_JOBS:-4}"
)
BINARY="$BINARY_DIR/kodi-ffmpeg-$TARGET$EXTENSION"
cp "$SOURCE_DIR/ffmpeg$EXTENSION" "$BINARY"
chmod +x "$BINARY"
"$BINARY" -version > "$BUILD_ROOT/version.txt"
grep -q 'LGPL version 2.1 or later' "$SOURCE_DIR/config.h" || {
  echo 'FFmpeg generated configuration did not confirm LGPL 2.1; refusing to package.' >&2; exit 1;
}
cp "$ARCHIVE" "$RESOURCE_DIR/ffmpeg-$VERSION.tar.xz"
cp "$ARCHIVE.asc" "$RESOURCE_DIR/ffmpeg-$VERSION.tar.xz.asc"
cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$RESOURCE_DIR/COPYING.LGPLv2.1"
cp "$BUILD_ROOT/version.txt" "$RESOURCE_DIR/ffmpeg-version.txt"
printf '%s\n' "Official FFmpeg $VERSION, unmodified source." "Source SHA256: $SOURCE_SHA256" "PGP signer: $SIGNER" "Target: $TARGET" "Configure arguments:" "${CONFIGURE[@]}" > "$RESOURCE_DIR/BUILD.txt"
printf '%s  %s\n' "$SOURCE_SHA256" "ffmpeg-$VERSION.tar.xz" > "$RESOURCE_DIR/SHA256SUMS"
printf 'Built verified audio codec: %s\n' "$BINARY"
