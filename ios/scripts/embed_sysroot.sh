#!/usr/bin/env bash
# Xcode build phase (post-build): embeds the frameworks iDeck actually
# needs from UTM's sysroot, the QEMU data files it uses, and the Vulkan ICD
# manifests, then signs them when the build is signed.
#
# UTM's sysroot has every QEMU target and all of its dependencies (~90
# frameworks, ~450 MB unpacked). iDeck embeds only the dependency closure of
# the app binary and qemu-aarch64-softmmu, plus libraries that are loaded
# with dlopen at runtime and therefore invisible to otool:
#   MoltenVK  - loaded by the Vulkan loader through MoltenVK_icd.json
#   EGL, GLESv2 - ANGLE, loaded by libepoxy for virgl
set -euo pipefail
: "${SYSROOT_DIR:?}" "${TARGET_BUILD_DIR:?}" "${FRAMEWORKS_FOLDER_PATH:?}" \
  "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}" "${EXECUTABLE_PATH:?}"

SRC="$SYSROOT_DIR/Frameworks"
DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
APP_BIN="${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"
mkdir -p "$DEST" "$RES"

[ -d "$SRC" ] || { echo "error: $SRC is missing. Run ios/scripts/fetch_sysroot.sh first." >&2; exit 1; }
[ -d "$SRC/qemu-aarch64-softmmu.framework" ] || { echo "error: qemu-aarch64-softmmu.framework not in $SRC" >&2; exit 1; }
[ -f "$APP_BIN" ] || { echo "error: app binary $APP_BIN not built yet" >&2; exit 1; }

fw_binary() {  # framework name -> binary path inside the sysroot
    local fw="$SRC/$1.framework"
    if [ -f "$fw/$1" ]; then echo "$fw/$1"; elif [ -f "$fw/Versions/Current/$1" ]; then echo "$fw/Versions/Current/$1"; fi
}

rpath_deps() {  # binary -> names of @rpath frameworks it loads
    otool -L "$1" | awk 'NR>1 {print $1}' | sed -n 's#^@rpath/\([^/]*\)\.framework/.*#\1#p'
}

# Xcode runs build phases with /bin/bash 3.2 (no associative arrays), so the
# set of needed frameworks is a newline-separated list.
needed=""
is_needed() { printf '%s\n' "$needed" | grep -qxF "$1"; }
queue=()
for n in qemu-aarch64-softmmu MoltenVK EGL GLESv2; do
    b="$(fw_binary "$n")"
    if [ -n "$b" ]; then needed="$needed"$'\n'"$n"; queue+=("$b"); fi
done
queue+=("$APP_BIN")
while [ ${#queue[@]} -gt 0 ]; do
    bin="${queue[0]}"
    queue=("${queue[@]:1}")
    for dep in $(rpath_deps "$bin"); do
        is_needed "$dep" && continue
        b="$(fw_binary "$dep")"
        [ -n "$b" ] || continue          # system framework or not in sysroot
        needed="$needed"$'\n'"$dep"
        queue+=("$b")
    done
done

# Remove frameworks from earlier builds that are no longer needed.
for fw in "$DEST"/*.framework; do
    [ -e "$fw" ] || continue
    n="$(basename "$fw" .framework)"
    if [ -d "$SRC/$n.framework" ] && ! is_needed "$n"; then rm -rf "$fw"; fi
done
count=0
for n in $needed; do
    count=$((count + 1))
    rsync -a --delete "$SRC/$n.framework/" "$DEST/$n.framework/"
    xattr -cr "$DEST/$n.framework" 2>/dev/null || true   # xattrs make codesign fail
done

# QEMU data (-L): direct kernel boot on "virt" needs no ROMs or firmware;
# keep only keymaps and the firmware descriptors.
mkdir -p "$RES/qemu"
for d in keymaps firmware; do
    [ -d "$SYSROOT_DIR/share/qemu/$d" ] && rsync -a --delete "$SYSROOT_DIR/share/qemu/$d/" "$RES/qemu/$d/"
done
# Vulkan ICD manifests (paths inside are bundle-relative).
if [ -d "$SYSROOT_DIR/share/vulkan" ]; then
    rsync -a --delete "$SYSROOT_DIR/share/vulkan/" "$RES/vulkan/"
fi

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    for fw in "$DEST"/*.framework; do
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,flags --timestamp=none "$fw"
    done
fi
echo "embedded $count frameworks:" $needed
