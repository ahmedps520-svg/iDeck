#!/usr/bin/env bash
# Rebuilds QEMU (aarch64-softmmu only) with iDeck's engine patches against
# UTM's dependency sysroot and replaces
# <sysroot>/Frameworks/qemu-aarch64-softmmu.framework.
#
#   build_qemu.sh <sysroot-dir>
#
# The QEMU in UTM's sysroot is built by UTM's scripts/build_dependencies.sh.
# This script runs the same script up to the point where it would start
# building, so the compiler, flags, SDK and UTM's own QEMU patch are the
# same, and then runs only the QEMU step with engine/qemu/*.patch applied on
# top, followed by UTM's framework fix-up. Everything else in the sysroot
# (virglrenderer, MoltenVK, ANGLE, SPICE, ...) stays UTM's prebuilt binary.
#
# About 10-20 minutes on a GitHub macOS runner.
set -euo pipefail
SYSROOT="$(cd "${1:?sysroot dir}" && pwd -P)"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UTM_TAG="v5.0.8"
UTM_COMMIT="535d6592a8bdc22b48de53703a371b80bf60d587"
SRC="$HERE/.utm-src"
FW="$SYSROOT/Frameworks/qemu-aarch64-softmmu.framework"
BIN="$FW/qemu-aarch64-softmmu"
WORK="$(mktemp -d)"

[ -f "$BIN" ] || { echo "error: $BIN is missing (run fetch_sysroot.sh first)" >&2; exit 1; }
shopt -s nullglob
PATCHES=("$ROOT"/engine/qemu/*.patch)
shopt -u nullglob
[ ${#PATCHES[@]} -gt 0 ] || { echo "error: no patches in engine/qemu" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$UTM_TAG" https://github.com/utmapp/UTM.git "$SRC"
fi
(cd "$SRC" && test "$(git rev-parse HEAD)" = "$UTM_COMMIT") || {
    echo "error: UTM checkout does not match pinned commit $UTM_COMMIT" >&2; exit 1; }

# What the prebuilt QEMU links against; the rebuilt one must match.
imports() { otool -L "$1" | awk 'NR>1 {print $1}' | sed 's#.*/##' | sort -u; }
imports "$BIN" > "$WORK/imports-utm.txt"

# pkg-config files record the path of the machine that built the sysroot.
OLD_PREFIX="$(sed -n 's/^prefix=//p' "$SYSROOT/lib/pkgconfig/glib-2.0.pc" | head -1)"
if [ -n "$OLD_PREFIX" ] && [ "$OLD_PREFIX" != "$SYSROOT" ]; then
    echo "Rewriting pkg-config prefix $OLD_PREFIX -> $SYSROOT"
    for dir in "$SYSROOT/lib/pkgconfig" "$SYSROOT/share/pkgconfig"; do
        [ -d "$dir" ] || continue
        grep -rlF "$OLD_PREFIX" "$dir" | while IFS= read -r f; do
            sed -i '' "s|$OLD_PREFIX|$SYSROOT|g" "$f"
        done
    done
fi

# UTM's script works on ./sysroot-iOS-arm64 and ./build-iOS-arm64.
rm -rf "$SRC/sysroot-iOS-arm64" "$SRC/build-iOS-arm64"
ln -s "$SYSROOT" "$SRC/sysroot-iOS-arm64"
mkdir -p "$SRC/build-iOS-arm64"

# UTM's script up to (not including) its "check_env" call, which is where
# it starts deleting and rebuilding the whole sysroot.
DRIVER="$SRC/scripts/ideck_build_qemu.sh"
awk '$0 == "check_env" {exit} {print}' "$SRC/scripts/build_dependencies.sh" > "$DRIVER"
grep -q '^build () {' "$DRIVER" || { echo "error: UTM's script changed shape" >&2; exit 1; }
if grep -q 'rm -rf "$PREFIX/"' "$DRIVER"; then
    echo "error: the copied part of UTM's script would delete the sysroot" >&2; exit 1
fi
cat >> "$DRIVER" <<'EOS'

# ---- iDeck: QEMU only -------------------------------------------------
if "$PREFIX/host/bin/pkg-config" --version >/dev/null 2>&1; then
    export PATH="$PREFIX/host/bin:$PATH"
    export PKG_CONFIG="$PREFIX/host/bin/pkg-config"
else
    PKG_CONFIG="$(command -v pkg-config)"
    export PKG_CONFIG
fi
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
echo "pkg-config: $PKG_CONFIG ($("$PKG_CONFIG" --version)); glib $("$PKG_CONFIG" --modversion glib-2.0)"

download $QEMU_SRC
OLDIFS=$IFS
IFS=:
for p in $IDECK_QEMU_PATCHES; do
    echo "${GREEN}Applying $(basename "$p")...${NC}"
    patch -d "$QEMU_DIR" -p1 < "$p"
done
IFS=$OLDIFS
build $QEMU_DIR --cross-prefix="" $QEMU_PLATFORM_BUILD_FLAGS $QEMU_DEBUG_FLAGS --target-list=aarch64-softmmu
"$BASEDIR/fixup.sh" -p "$PLATFORM" -s "$PREFIX" -m "$SDKMINVER" "$PREFIX/lib/libqemu-aarch64-softmmu.dylib"
EOS

IDECK_QEMU_PATCHES="$(IFS=:; echo "${PATCHES[*]}")"
export IDECK_QEMU_PATCHES
(cd "$SRC" && sh scripts/ideck_build_qemu.sh -p ios -a arm64)

# The framework must be the new build, with the same dependencies as UTM's.
[ -f "$BIN" ] || { echo "error: $BIN is missing after the build" >&2; exit 1; }
imports "$BIN" > "$WORK/imports-new.txt"
if ! diff -u "$WORK/imports-utm.txt" "$WORK/imports-new.txt"; then
    echo "error: the rebuilt QEMU links a different set of libraries than UTM's" >&2
    exit 1
fi
# grep -c reads all of its input; with -q, strings would die of SIGPIPE and
# pipefail would report that as a failure.
if [ "$(strings -a "$BIN" | grep -c 'x-host-vfp')" -eq 0 ]; then
    echo "error: the rebuilt QEMU does not contain the engine patches" >&2
    exit 1
fi
lipo -archs "$BIN"
ls -la "$BIN"
echo "QEMU rebuilt with ${#PATCHES[@]} engine patch(es): $FW"
