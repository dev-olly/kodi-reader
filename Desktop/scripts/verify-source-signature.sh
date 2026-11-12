#!/usr/bin/env bash
# Verify only public release material. No private keyring, agent or trustdb.
set -euo pipefail
[[ $# == 4 ]] || { echo 'Supply source archive, detached signature, armored public key and pinned signer fingerprint.' >&2; exit 1; }
ARCHIVE=$1
SIGNATURE=$2
PUBLIC_KEY=$3
SIGNER=$4
[[ "$SIGNER" =~ ^[A-F0-9]{40}$ ]] || { echo 'A full uppercase pinned signing fingerprint is required.' >&2; exit 1; }
KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
chmod 700 "$KEY_DIR"
# Importing even a public key can start gpg-agent on MSYS2. Dearmor instead;
# gpgv uses this explicit keyring and never consults a user's trusted keys.
gpg --homedir "$KEY_DIR" --batch --yes --dearmor --output "$KEY_DIR/release-key.gpg" "$PUBLIC_KEY"
gpgv --homedir "$KEY_DIR" --keyring "$KEY_DIR/release-key.gpg" --status-fd 1 "$SIGNATURE" "$ARCHIVE" > "$KEY_DIR/status.txt"
awk -v fingerprint="$SIGNER" '$2 == "VALIDSIG" && ($3 == fingerprint || $NF == fingerprint) { valid=1 } END { exit !valid }' "$KEY_DIR/status.txt" || {
  echo 'Release signature does not match its pinned signing key.' >&2; exit 1;
}
cat "$KEY_DIR/status.txt"
