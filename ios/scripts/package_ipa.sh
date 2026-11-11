#!/usr/bin/env bash
# Packages an unsigned .xcarchive as an IPA for sideloading. Sideloading
# tools (Sideloadly, AltStore/SideStore, Feather, Xcode) re-sign it with the
# user's Apple ID using development signing, which keeps get-task-allow so
# StikDebug can enable JIT.
#   package_ipa.sh path/to/iDeck.xcarchive out/iDeck.ipa
set -euo pipefail
ARCHIVE="${1:?xcarchive}"
OUT="${2:?output ipa}"
APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
[ -n "$APP" ] || { echo "no .app in $ARCHIVE" >&2; exit 1; }
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
# Strip any leftover signatures so re-signing tools start clean.
find "$WORK/Payload" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
(cd "$WORK" && zip -qry -X "ipa.zip" Payload)
mkdir -p "$(dirname "$OUT")"
mv "$WORK/ipa.zip" "$OUT"
echo "IPA: $OUT ($(du -h "$OUT" | cut -f1))"
