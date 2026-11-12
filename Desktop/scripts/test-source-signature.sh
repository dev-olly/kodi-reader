#!/usr/bin/env bash
# Exercise the real public release signature, not a mocked verifier.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Supply archive, detached signature, public key and pinned signer.' >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE=$1
SIGNATURE=$2
PUBLIC_KEY=$3
SIGNER=$4
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
bash "$SCRIPT_DIR/verify-source-signature.sh" "$ARCHIVE" "$SIGNATURE" "$PUBLIC_KEY" "$SIGNER" > "$TEST_DIR/valid.txt"
cp "$ARCHIVE" "$TEST_DIR/tampered.tar.xz"
# XZ archives begin with 0xFD; replacing it with zero changes signed bytes.
printf '\0' | dd of="$TEST_DIR/tampered.tar.xz" bs=1 count=1 conv=notrunc 2>/dev/null
if bash "$SCRIPT_DIR/verify-source-signature.sh" "$TEST_DIR/tampered.tar.xz" "$SIGNATURE" "$PUBLIC_KEY" "$SIGNER" > "$TEST_DIR/tampered.txt" 2>&1; then
  echo 'Signature verification accepted tampered source bytes.' >&2; exit 1
fi
if bash "$SCRIPT_DIR/verify-source-signature.sh" "$ARCHIVE" "$SIGNATURE" "$PUBLIC_KEY" 0000000000000000000000000000000000000000 > "$TEST_DIR/wrong-pin.txt" 2>&1; then
  echo 'Signature verification accepted an unpinned signer.' >&2; exit 1
fi
echo 'Real source signature passed; tampered bytes and a wrong signer pin were rejected.'
