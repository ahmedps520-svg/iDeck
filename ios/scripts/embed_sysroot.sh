#!/usr/bin/env bash
# Xcode build phase: copies every framework from UTM's sysroot into the app
# (including qemu-aarch64-softmmu.framework, MoltenVK, virglrenderer,
# ANGLE), plus QEMU's data files and the Vulkan ICD manifests, and signs
# them when the build is signed.
set -euo pipefail
: "${SYSROOT_DIR:?}" "${TARGET_BUILD_DIR:?}" "${FRAMEWORKS_FOLDER_PATH:?}" "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "$DEST" "$RES"

if [ ! -d "$SYSROOT_DIR/Frameworks" ]; then
    echo "error: $SYSROOT_DIR is missing. Run ios/scripts/fetch_sysroot.sh first." >&2
    exit 1
fi
if [ ! -d "$SYSROOT_DIR/Frameworks/qemu-aarch64-softmmu.framework" ]; then
    echo "error: qemu-aarch64-softmmu.framework not found in $SYSROOT_DIR" >&2
    exit 1
fi

for fw in "$SYSROOT_DIR"/Frameworks/*.framework; do
    name="$(basename "$fw")"
    rsync -a --delete "$fw/" "$DEST/$name/"
    # Extended attributes make codesign reject the bundle.
    xattr -cr "$DEST/$name" 2>/dev/null || true
done

# QEMU data directory (-L): firmware blobs and keymaps.
if [ -d "$SYSROOT_DIR/share/qemu" ]; then
    rsync -a --delete "$SYSROOT_DIR/share/qemu/" "$RES/qemu/"
fi
# Vulkan ICD manifests (MoltenVK, KosmicKrisp); paths are bundle-relative.
if [ -d "$SYSROOT_DIR/share/vulkan" ]; then
    rsync -a --delete "$SYSROOT_DIR/share/vulkan/" "$RES/vulkan/"
fi

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    for fw in "$DEST"/*.framework; do
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,flags --timestamp=none "$fw"
    done
fi
echo "embedded $(ls -1d "$DEST"/*.framework | wc -l | tr -d ' ') frameworks"
