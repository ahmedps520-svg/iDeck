#!/usr/bin/env bash
# Provides UTM's prebuilt iOS dependency sysroot at ios/sysroot-<platform>-arm64.
#
#   fetch_sysroot.sh [ios|ios-tci]
#
# 1. If GITHUB_TOKEN is set, download the "Sysroot-<platform>-arm64"
#    artifact published by UTM's release build for the pinned UTM tag.
# 2. Otherwise (or if the artifact has expired), build it from source with
#    UTM's scripts/build_dependencies.sh at the pinned tag (1.5-3 hours on a
#    GitHub macOS runner; CI caches the result).
set -euo pipefail
PLATFORM="${1:-ios}"
UTM_TAG="v5.0.8"
UTM_COMMIT="535d6592a8bdc22b48de53703a371b80bf60d587"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
case "$PLATFORM" in
    ios) NAME="sysroot-iOS-arm64"; ARTIFACT="Sysroot-ios-arm64" ;;
    ios-tci) NAME="sysroot-iOS-TCI-arm64"; ARTIFACT="Sysroot-ios-tci-arm64" ;;
    *) echo "unknown platform $PLATFORM" >&2; exit 2 ;;
esac
DEST="$HERE/$NAME"
if [ -d "$DEST/Frameworks" ]; then
    echo "$DEST already present"
    exit 0
fi

try_artifact() {
    [ -n "${GITHUB_TOKEN:-}" ] || return 1
    command -v gh >/dev/null || return 1
    echo "Looking for UTM release build artifact $ARTIFACT ($UTM_TAG)…"
    local run
    run=$(gh api -H "Accept: application/vnd.github+json" \
        "repos/utmapp/UTM/actions/runs?head_sha=$UTM_COMMIT&event=release&status=success" \
        --jq '.workflow_runs[0].id' 2>/dev/null || true)
    [ -n "$run" ] && [ "$run" != "null" ] || return 1
    local id
    id=$(gh api "repos/utmapp/UTM/actions/runs/$run/artifacts" \
        --jq ".artifacts[] | select(.name==\"$ARTIFACT\" and .expired==false) | .id" 2>/dev/null | head -1)
    [ -n "$id" ] || return 1
    local tmp
    tmp=$(mktemp -d)
    gh api "repos/utmapp/UTM/actions/artifacts/$id/zip" > "$tmp/a.zip" || return 1
    (cd "$tmp" && unzip -q a.zip)
    # The artifact contains a tarball of the sysroot directory.
    local tarball
    tarball=$(find "$tmp" -name '*.tgz' -o -name '*.tar.gz' -o -name '*.tar.xz' | head -1)
    if [ -n "$tarball" ]; then
        tar -xf "$tarball" -C "$tmp"
    fi
    local found
    found=$(find "$tmp" -maxdepth 3 -type d -name 'sysroot-*' | head -1)
    [ -n "$found" ] && [ -d "$found/Frameworks" ] || return 1
    mv "$found" "$DEST"
    echo "Using UTM's prebuilt $ARTIFACT"
}

build_from_source() {
    echo "Building UTM dependencies from source ($UTM_TAG, $PLATFORM)…"
    local src="$HERE/.utm-src"
    if [ ! -d "$src/.git" ]; then
        git clone --depth 1 --branch "$UTM_TAG" https://github.com/utmapp/UTM.git "$src"
    fi
    (cd "$src" && test "$(git rev-parse HEAD)" = "$UTM_COMMIT") || {
        echo "UTM checkout does not match pinned commit $UTM_COMMIT" >&2; exit 1; }
    (cd "$src" && ./scripts/build_dependencies.sh -p "$PLATFORM" -a arm64)
    mv "$src/$NAME" "$DEST"
}

try_artifact || build_from_source
test -d "$DEST/Frameworks/qemu-aarch64-softmmu.framework" || {
    echo "sysroot has no qemu-aarch64-softmmu.framework" >&2; exit 1; }
echo "Sysroot ready: $DEST"
