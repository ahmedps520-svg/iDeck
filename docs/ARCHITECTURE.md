# Architecture

## Decision: hybrid (option C)

The prompt offered three options: (A) a custom ARM64 engine, (B) an existing emulator adapted to
iPadOS, or (C) a hybrid of existing components plus custom integration. iDeck uses **C**:

| Layer | Choice | Why |
|---|---|---|
| CPU | QEMU 10.0.12 **utmapp fork**, TCG JIT, in-process | The only open-source engine that already runs Linux guests on iPadOS 26+/27 with debugger-assisted JIT (TXM). Hypervisor.framework is not available to iPad apps. Writing a new engine would not beat TCG soon. |
| GPU | virtio-gpu-gl + **Venus** (Vulkan) and **virgl** (GL) → virglrenderer (utmapp fork, thread render server) → MoltenVK / ANGLE-Metal | Shipping on iOS in UTM 5.0. Guest Mesa has the Venus driver. |
| Display, audio, pointer | SPICE via **CocoaSpice** | Zero-copy Metal presentation, SPICE playback audio, keyboard and mouse channels |
| Guest | Debian 13 arm64, 4 KiB pages, Xorg + openbox | The Steam ARM64 client and FEX both require 4 KiB pages. Xorg uses GL (virgl), which works. Vulkan compositing does not. |
| Steam | Valve's native **linuxarm64** client | Required for Proton ARM64. Avoids running x86 Steam under FEX. |
| x86 / Windows | Steam's FEX tool + FEX RootFS; Proton ARM64 (arm64ec + FEX) | Valve's own path for ARM64 (Steam Frame) |
| Glue | iDeck core (C++), guest agent (C++), Swift app | Written for this project |

Henge (Leviidev/Henge) was studied. Its near-identity ARM64→ARM64 translator is
faster in principle, but Henge emulates macOS guests with Apple's paravirtual GPU
and has no virtio-gpu, it is GPL-2.0+, and it was nine days old. iDeck reuses
none of its code. It is noted as a future direction in [CPU_ENGINE](CPU_ENGINE.md).

## Process and threads on the iPad

```
iDeck.app (one process)
├─ main thread: SwiftUI, RuntimeController, installer
├─ QEMU thread (QOS user-interactive, 8 MiB stack): qemu_init → qemu_main_loop
│   ├─ vCPU threads (MTTCG, one per vCPU)
│   ├─ virglrenderer render-server thread (Venus) → MoltenVK → Metal
│   └─ I/O threads (aio=threads for disks)
├─ spice-glib main loop thread (CocoaSpice): display, inputs, playback
└─ socket queues: QMP, agent control, agent input (Unix sockets in tmp/)
```

iOS apps cannot fork, so QEMU is `dlopen`ed from
`Frameworks/qemu-aarch64-softmmu.framework` and started on its own thread
(`ios/iDeck/Native/IDQemuLauncher.m`). An `atexit_b` handler turns QEMU's
`exit()` into `pthread_exit` on that thread. QEMU's global state means it can
only start once per app launch, so after Linux shuts down the app asks to be
relaunched.

## Channels

| Channel | Transport | Purpose |
|---|---|---|
| SPICE | Unix socket `s.sock` | Display (GL scanout as a Metal texture), audio playback, keyboard/mouse, vdagent (resolution, clipboard) |
| QMP | Unix socket `q.sock` | Balloon, `block_resize`, power-down, status, screendump (CI) |
| Agent control | virtio-serial `org.ideck.control` | JSON lines: status, metrics, provisioning, Steam control, self-test, benchmarks, time sync |
| Agent input | virtio-serial `org.ideck.input` | 32-byte controller packets in, rumble packets out |

The protocol definitions live in `core/include/ideck/protocol.hpp`. The app, the
CI host (`tools/ideck_host.py`) and the agent all use them, so the two ends can
never disagree.

## Shared core

`core/` is plain C++17 with no dependencies. It is compiled into the iOS app
(through `ideck_core.h`), into the CI test host (as a shared library through
ctypes), and partly into the guest agent. It contains:

- `memory_planner`: chooses the guest RAM tier (2/3/4/5/6 GiB), TCG cache size and Venus hostmem from the measured jetsam limit, and sets the memory-pressure policy.
- `qemu_args`: builds the full QEMU command line for the iOS profile and the desktop test profile.
- `journal`: the persistent install state machine (resume, retry, roll back).
- `manifest`: runtime manifest parsing and validation (HTTPS only, SHA-256, safe names).
- `storage`: data-disk growth policy, sparse files, APFS clones.
- `protocol`, `qmp`: wire formats.
- `sha256`, `json`, `fsutil`: building blocks.

## Storage layout (iPad)

```
Application Support/iDeck/        (excluded from iCloud backup)
  runtime/<version>/Image, initrd.img, system.img     replaced on update; previous kept for rollback
  runtime/current
  library/data.img                 sparse, whole-disk ext4 (/home in Linux): Steam, games, saves
  library/snapshots/*.img          APFS clones
  state/install-journal.json, manifest.json, settings.json
Caches/iDeck/downloads/            resumable runtime downloads
tmp/ideck/                         sockets, qemu.log, console.log
<external folder>/ideck-library-external.img   optional USB-C SSD library (/mnt/external)
```

The system disk is disposable. Everything the user owns lives on `data.img`,
so runtime updates never touch games or saves.

## Boot flow (Start Gaming)

1. `memory.plan` from `os_proc_available_memory()` and the footprint.
2. Ensure `data.img`, and grow it if the library was nearly full.
3. `qemu.args`, then the environment: `ANGLE_DEFAULT_PLATFORM=metal`, `VK_DRIVER_FILES=MoltenVK_icd.json`, `APP_SANDBOX_GROUP_ID`.
4. Start QEMU. Connect QMP, the agent, input and SPICE.
5. The guest boots. systemd starts `ideck-agent`, which emits `ready`.
6. The app sends `time.sync` and `steam.configure`, then starts Steam if it is not running.
7. `ideck-session` (Xorg + openbox) and `ideck-steam` (`steamrtarm64/steam`) show Steam.

First boot additionally runs `ideck-provision` (Steam bootstrap, FEX RootFS,
self-test). Its progress drives the remaining installer steps.
