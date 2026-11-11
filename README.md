# iDeck

**Steam on iPad, running locally.** iDeck is a native iPadOS app that boots a
minimal ARM64 Linux system in an emulated machine on the iPad itself, installs
Valve's native ARM64 Steam desktop client inside it, and shows it full-screen
with controller, keyboard, mouse, touch and audio support. No PC, cloud
service or streaming is involved in gameplay.

> **Status: v0.1.0, first complete implementation, not yet run on an iPad.**
> All components are written. Everything that can be tested on Windows has
> been built and tested here (see [TEST_RESULTS](docs/TEST_RESULTS.md)). The iOS
> app build, the Linux image build and the boot/Steam test run in GitHub Actions
> and have not been executed yet. Nothing in this repository claims that a
> Steam game has run on an iPad.

## How it works

```
iDeck (SwiftUI)  ── one-tap installer, library, downloads, performance, controls
  │  core (C++17, shared with CI): memory planner, QEMU args, journal, protocols
  ├─ QEMU 10 (utmapp fork) in-process, TCG JIT via StikDebug (iPadOS 26+/27)
  │    virtio-gpu-gl + Venus ── virglrenderer ── MoltenVK / ANGLE ── Metal ── M5 GPU
  │    SPICE (CocoaSpice) ── display (zero-copy Metal), audio, keyboard/mouse
  │    virtio-serial ── ideck-agent (control, metrics, virtual Xbox pads, rumble)
  └─ Debian 13 arm64 guest ── Xorg + openbox ── Steam (native linuxarm64 client)
         ├─ native ARM64 Linux games
         ├─ x86-64 Linux games ── Steam's FEX tool + FEX RootFS
         └─ Windows games ── Proton ARM64 (arm64ec + FEX) ── DXVK / VKD3D-Proton
```

Details: [ARCHITECTURE](docs/ARCHITECTURE.md).

## What you do

1. Install the IPA. It is built by GitHub Actions, and you sign it with your Apple ID using Sideloadly, AltStore or SideStore.
2. Enable JIT with StikDebug and open iDeck.
3. Tap **Install iDeck**. It downloads and verifies the Linux runtime, creates game storage and boots Linux. Linux then installs Steam and checks graphics, audio and controllers.
4. Tap **Start Gaming**. The Steam client opens. Sign in and install a game.
5. Press Play.

Step by step: [INSTALLATION](docs/INSTALLATION.md). Why TestFlight cannot do
this: [DISTRIBUTION](docs/DISTRIBUTION.md).

## Repository

| Path | What |
|---|---|
| `core/` | C++17 runtime core and its C API (`ideck_core.h`) used by the app, CI and tests |
| `ios/` | SwiftUI app, Objective-C QEMU launcher and SPICE client, XcodeGen spec, build scripts |
| `guest/agent/` | `ideck-agent`, the guest agent (static aarch64 binary) |
| `guest/rootfs/` | Guest system files: systemd units, Steam bootstrapper, provisioning, self-test |
| `linux/` | Reproducible image build (mmdebstrap, Debian 13 arm64) |
| `bench/` | CPU and memory micro-benchmarks run inside the guest |
| `tools/` | Local build/test driver, manifest and kernel tools, CI boot-test host |
| `.github/workflows/` | CI, Linux runtime build and boot test, iOS IPA and TestFlight builds |
| `docs/` | Documentation |

## Documentation

[ARCHITECTURE](docs/ARCHITECTURE.md) ·
[BUILD](docs/BUILD.md) ·
[INSTALLATION](docs/INSTALLATION.md) ·
[LINUX](docs/LINUX.md) ·
[CPU_ENGINE](docs/CPU_ENGINE.md) ·
[GRAPHICS](docs/GRAPHICS.md) ·
[STEAM](docs/STEAM.md) ·
[COMPATIBILITY](docs/COMPATIBILITY.md) ·
[PERFORMANCE](docs/PERFORMANCE.md) ·
[DISTRIBUTION](docs/DISTRIBUTION.md) ·
[TROUBLESHOOTING](docs/TROUBLESHOOTING.md) ·
[TEST_RESULTS](docs/TEST_RESULTS.md)

## Honest expectations

- The CPU is emulated. TCG translates ARM64 to ARM64, and x86 games add FEX translation inside the guest on top of that. Expect light 2D and older 3D games to be the realistic target. Demanding games will not reach 30 FPS. [PERFORMANCE](docs/PERFORMANCE.md) explains how performance is measured; no figures from a real iPad exist yet.
- Valve ships the ARM64 Linux client publicly on its CDN, but does not support it on general ARM Linux. It may change without notice ([STEAM](docs/STEAM.md)).
- DXVK 3.x needs Vulkan 1.4 features that Vulkan-on-Metal does not fully provide yet. Some D3D games will not render ([GRAPHICS](docs/GRAPHICS.md)).
- Kernel-level anti-cheat games will not run.

## License

iDeck's own code is MIT licensed (see `LICENSE`). The app bundles third-party
components under their own licenses, including QEMU (GPL-2.0) and
virglrenderer, MoltenVK, ANGLE, spice-gtk, GLib and GStreamer (LGPL/MIT/Apache).
See [`THIRD_PARTY.md`](THIRD_PARTY.md).
