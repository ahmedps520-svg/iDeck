# The Linux guest

## Base

- **Debian 13 "trixie" arm64**, `minbase` plus `linux/packages.txt` (no desktop environment, no display manager).
- **Kernel:** Debian `linux-image-arm64` (6.12 LTS) with 4 KiB pages, which both the Steam ARM64 client and FEX require. It boots directly with `-kernel/-initrd` and no firmware. `tools/extract_kernel.py` turns Debian's `vmlinuz` (raw, gzip or EFI zboot) into a raw `Image`.
- **Mesa** from `trixie-backports` (26.x), which provides the Venus Vulkan driver (`libvulkan_virtio.so`) and virgl.
- **Users:** `deck` (uid 1000) runs the session and Steam. Root and deck passwords are locked; nothing listens on the network.

## Disks

| Device | Mount | Source | Lifetime |
|---|---|---|---|
| `/dev/vda` | `/` | `system.img` (runtime) | replaced by runtime updates |
| `/dev/disk/by-id/virtio-ideck-data` | `/home` | `data.img` | permanent: Steam, games, saves |
| `virtio-ideck-ext0` | `/mnt/external` | external SSD image (optional) | permanent |

`/home` is a whole-disk ext4 with `x-systemd.makefs`, so a blank disk is
formatted on first boot, and `x-systemd.growfs`, so the filesystem grows to the
image size at every boot. While Linux runs, iDeck grows the image file, sends
QMP `block_resize`, and the agent runs `resize2fs` online.

## Services (`guest/rootfs/etc/systemd/system`)

| Unit | Role |
|---|---|
| `ideck-agent.service` | Host channel (starts early in `sysinit`) |
| `ideck-home.service` | Creates `/home/deck` on a fresh library disk |
| `ideck-session.service` | Xorg (modesetting + glamor on virtio-gpu) and openbox, in a real logind session on tty1 (PipeWire user services, DRM access) |
| `ideck-steam.service` | `ideck-steam-launch`: bootstraps Steam if needed, then runs `steamrtarm64/steam` |
| `ideck-provision.service` | First-boot setup, idempotent. Later boots take a fast path. |
| `ideck-fex-rootfs.service` | Loop-mounts the FEX RootFS from the library disk at `/usr/share/guestos/fex-mesa` |

Journald keeps logs in RAM, and the apt/man/fstrim timers are masked so there is
less background work under emulation.

## Provisioning (`/usr/lib/ideck/provision.py`)

Writes `/var/lib/ideck/provision.json`, which the agent streams to the app:
`install-steam` → `install-compat` → `init-graphics` → `init-audio` →
`init-input` → `self-test`. Each step is idempotent. A stamp on the library disk
(`/home/.ideck/provisioned-<version>.json`) lets later boots skip straight to
Steam.

## Self-test (`/usr/lib/ideck/self_test.py`)

Checks the page size (4 KiB), LSE atomics, library mount, DNS, the DRM render
node, the OpenGL renderer (must not be llvmpipe), the Vulkan device (must not be
llvmpipe), the PipeWire sink, uinput, the agent, the Steam client binary, the FEX
RootFS and unprivileged user namespaces (Steam Runtime containers need them).

## Recovery

- **Repair Setup** re-runs the in-guest provisioning.
- **Roll Back Runtime** boots the previous system disk.
- The serial console log (`console.log`) and QEMU log are viewable and shareable from the Runtime screen.
- **Software-rendered Steam UI** (Settings) works around CEF GPU problems.
- Turning Vulkan off in Settings boots with virgl only.

## Building

See [BUILD](BUILD.md) and `linux/build-image.sh`. It must run as root on an
arm64 host so that package maintainer scripts run natively without qemu-user.
