#!/usr/bin/env bash
# Packages an unsigned .xcarchive as an IPA for sideloading. Sideloading
# tools (Sideloadly, AltStore/SideStore, Feather, Xcode) re-sign it with the
# user's Apple ID using development signing, which keeps get-task-allow so
# StikDebug can enable JIT.
#   package_ipa.sh path/to/iDeck.xcarchive out/iDeck.ipa [entitlements.plist]
# With an entitlements file, the main executable is ad-hoc signed with it
# (ldid). SideStore and AltStore read those entitlements to decide which
# capabilities (app group, memory limit) to request; Sideloadly's IPA stays
# unsigned.
set -euo pipefail
ARCHIVE="${1:?xcarchive}"
OUT="${2:?output ipa}"
ENTITLEMENTS="${3:-}"
APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
[ -n "$APP" ] || { echo "no .app in $ARCHIVE" >&2; exit 1; }
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
# Strip any leftover signatures so re-signing tools start clean.
find "$WORK/Payload" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
if [ -n "$ENTITLEMENTS" ]; then
  command -v ldid >/dev/null || { echo "ldid is needed to embed entitlements (brew install ldid)" >&2; exit 1; }
  BUNDLE="$WORK/Payload/$(basename "$APP")"
  EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BUNDLE/Info.plist")
  ldid -S"$ENTITLEMENTS" "$BUNDLE/$EXE"
  echo "signed $EXE (ad hoc) with $(basename "$ENTITLEMENTS"):"
  ldid -e "$BUNDLE/$EXE"
fi
(cd "$WORK" && zip -qry -X "ipa.zip" Payload)
mkdir -p "$(dirname "$OUT")"
mv "$WORK/ipa.zip" "$OUT"
echo "IPA: $OUT ($(du -h "$OUT" | cut -f1))"
