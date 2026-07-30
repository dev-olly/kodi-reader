#!/usr/bin/env bash
# Downloads the Project Gutenberg books the EpubKit tests read from.
# They are not committed, so run this once after cloning.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Samples
cd Samples

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

# frankenstein and alice ship an EPUB 3 navigation document;
# pride-and-prejudice has only an NCX, which covers the EPUB 2 code path.
fetch() {
  local name=$1 url=$2
  if [[ -f "$name" ]]; then
    echo "have    $name"
    return
  fi
  echo "fetch   $name"
  curl -fsSL -A "$UA" -o "$name" "$url"
}

fetch frankenstein.epub       "https://www.gutenberg.org/ebooks/84.epub3.images"
fetch alice.epub              "https://www.gutenberg.org/ebooks/11.epub3.images"
fetch pride-and-prejudice.epub "https://www.gutenberg.org/ebooks/1342.epub.noimages"

echo
ls -lh ./*.epub
