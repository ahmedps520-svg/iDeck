#!/usr/bin/env bash
# Builds the iDeck guest runtime: Debian 13 (trixie) arm64, minimal, booting
# straight into Xorg + Steam. Must run as root on an arm64 Debian/Ubuntu host
# (GitHub's ubuntu-24.04-arm runners), so package scripts run natively.
#
#   sudo linux/build-image.sh --version 0.1.0 --agent build/core/ideck-agent-aarch64-linux-musl \
#        --bench build/core/ideck-bench-aarch64-linux-musl --out out/
#
# Outputs in --out: Image (raw arm64 kernel), initrd.img, system.img (sparse
# ext4), packages.lock (exact package versions), guest-info.json.
set -euo pipefail

VERSION=""
AGENT=""
BENCH=""
OUT=""
SUITE="trixie"
MIRROR="http://deb.debian.org/debian"
SECURITY="http://security.debian.org/debian-security"
SNAPSHOT=""        # e.g. 20261110T000000Z for a reproducible snapshot.debian.org build
EXTRA_MB=1024      # free space left in the system image

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        --bench) BENCH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --snapshot) SNAPSHOT="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -n "$VERSION" ] && [ -f "$AGENT" ] && [ -f "$BENCH" ] && [ -n "$OUT" ] || {
    echo "usage: $0 --version V --agent PATH --bench PATH --out DIR [--snapshot TS]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "must run on an arm64 host" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /var/tmp/ideck-image.XXXXXX)"
ROOT="$WORK/rootfs"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cleanup_mounts() { umount -lR "$ROOT/dev" 2>/dev/null || true; umount -l "$ROOT/sys" "$ROOT/proc" 2>/dev/null || true; }
trap cleanup_mounts EXIT

if [ -n "$SNAPSHOT" ]; then
    MIRROR="http://snapshot.debian.org/archive/debian/$SNAPSHOT"
    SECURITY="http://snapshot.debian.org/archive/debian-security/$SNAPSHOT"
    SOURCE_DATE_EPOCH="$(date -d "${SNAPSHOT:0:8}" +%s)"
    export SOURCE_DATE_EPOCH
fi
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$HERE" log -1 --format=%ct 2>/dev/null || date +%s)}"

PKGS="$(grep -v -E '^\s*(#|$)' "$HERE/linux/packages.txt" | tr '\n' ',' | sed 's/,$//')"

echo "==> mmdebstrap $SUITE ($MIRROR)"
mmdebstrap \
    --arch=arm64 \
    --variant=minbase \
    --components="main contrib non-free-firmware" \
    --include="$PKGS" \
    --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    --aptopt='Acquire::Retries "5"' \
    --aptopt='APT::Install-Recommends "false"' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/locale/*' \
    --dpkgopt='path-include=/usr/share/locale/en*' \
    --customize-hook='chroot "$1" apt-get install -y -t '"$SUITE"'-backports \
        mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 mesa-libgallium' \
    "$SUITE" "$ROOT" \
    "deb $MIRROR $SUITE main contrib non-free-firmware" \
    "deb $MIRROR $SUITE-updates main contrib non-free-firmware" \
    "deb $MIRROR $SUITE-backports main contrib non-free-firmware" \
    "deb $SECURITY $SUITE-security main contrib non-free-firmware"

echo "==> installing iDeck files"
cp -a "$HERE/guest/rootfs/." "$ROOT/"
install -m 0755 "$AGENT" "$ROOT/usr/lib/ideck/ideck-agent"
install -m 0755 "$BENCH" "$ROOT/usr/lib/ideck/ideck-bench"
chmod 0755 "$ROOT"/usr/lib/ideck/{ideck-steam-launch,ideck-steam-url,session,set-resolution,init-home,zram-swap} \
           "$ROOT"/usr/lib/ideck/*.py
echo "$VERSION" > "$ROOT/usr/lib/ideck/runtime-version"
python3 "$HERE/linux/fex_components.py" "$ROOT/usr/lib/ideck/components.json"

echo "==> configuring system"
echo ideck > "$ROOT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tideck\n' > "$ROOT/etc/hosts"
echo "en_US.UTF-8 UTF-8" > "$ROOT/etc/locale.gen"
echo "LANG=en_US.UTF-8" > "$ROOT/etc/default/locale"
mount -t proc proc "$ROOT/proc"
# Fresh sysfs rather than a recursive bind of the host's: no cgroup
# submounts that keep it busy at unmount time.
mount -t sysfs sysfs "$ROOT/sys"
mount --rbind /dev "$ROOT/dev"
mount --make-rslave "$ROOT/dev"
chroot "$ROOT" /bin/sh -eux <<'CHROOT'
locale-gen
useradd -m -u 1000 -U -G audio,video,render,input -s /bin/bash deck
passwd -l root
passwd -l deck
systemctl enable ideck-agent.service ideck-home.service ideck-session.service ideck-steam.service \
    ideck-provision.service ideck-fex-rootfs.service ideck-zram.service systemd-networkd.service systemd-resolved.service
systemctl set-default graphical.target
systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer e2scrub_all.timer fstrim.timer \
    getty@tty1.service systemd-networkd-wait-online.service
# PipeWire user units are enabled globally by the packages; make sure.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
update-initramfs -u -k all
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/log/*.log /tmp/* /var/tmp/*
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' > /usr/lib/ideck/packages.lock
CHROOT
cleanup_mounts
# /home is the separate library disk; keep the mount point empty.
rm -rf "$ROOT/home/deck"
mkdir -p "$ROOT/home"

echo "==> kernel and initrd"
KVER="$(ls "$ROOT/lib/modules" | sort -V | tail -1)"
python3 "$HERE/tools/extract_kernel.py" "$ROOT/boot/vmlinuz-$KVER" "$OUT/Image"
cp "$ROOT/boot/initrd.img-$KVER" "$OUT/initrd.img"
cp "$ROOT/usr/lib/ideck/packages.lock" "$OUT/packages.lock"

MESA="$(awk '$1=="mesa-vulkan-drivers"{print $2}' "$OUT/packages.lock")"
python3 - "$OUT/guest-info.json" "$VERSION" "$KVER" "$MESA" <<'PY'
import json, sys
out, version, kver, mesa = sys.argv[1:]
json.dump({"distro": "debian-13-trixie", "arch": "aarch64", "runtime_version": version,
           "kernel": kver, "mesa": mesa, "steam": "native linuxarm64 client (installed at first boot)",
           "page_size": 4096}, open(out, "w"), indent=2)
PY

echo "==> system image"
USED_MB=$(du -sm --apparent-size "$ROOT" | cut -f1)
SIZE_MB=$(( (USED_MB * 125 / 100 + EXTRA_MB + 255) / 256 * 256 ))
rm -f "$OUT/system.img"
E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" mke2fs -q -t ext4 -L ideck-system -b 4096 -m 1 \
    -U 5d1dec00-1dec-4dec-8dec-000000000001 -E root_owner=0:0,hash_seed=1dec1dec-1dec-4dec-8dec-1dec1dec1dec \
    -d "$ROOT" "$OUT/system.img" "${SIZE_MB}M"
e2fsck -fn "$OUT/system.img"
echo "system.img: ${SIZE_MB} MiB logical, $(du -h "$OUT/system.img" | cut -f1) allocated"
rm -rf "$WORK"
echo "done: $OUT"
