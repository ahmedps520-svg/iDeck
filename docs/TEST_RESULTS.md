# Test results

Every row says where and when it ran. "Not run" means exactly that. No result
here comes from an iPad yet.

## Session 1: 2026-11-11, Windows 11 development PC (Intel i5-14600K), no Mac, no iPad

### Verified here

| What | Result | How |
|---|---|---|
| Core unit tests (native Windows x86-64, Zig clang 19) | **32 tests, 327 checks, 0 failures** | `python tools/build_core.py test` |
| Bugs the tests caught and that were fixed | QMP negotiation id collided with a command queued before the greeting. The journal demoted running steps on every load (broke the C API between calls). | tests in `core/tests/test_vm.cpp` |
| Guest agent unit tests (Windows) | **3 tests, 11 checks, 0 failures** (the uinput mapping test only compiles for Linux; CI runs it on arm64 Linux) | `python tools/build_core.py agent` |
| Cross-compile for the guest | `ideck-agent` (733 KB), `ideck-bench`, core and agent tests: aarch64-linux-musl and x86_64-linux-musl, **no warnings with `-Werror`** | `build_core.py all --target aarch64-linux-musl` |
| Python tests | **11 run, 0 failures, 2 skipped** on Windows (the POSIX symlink/exec-bit install test runs in CI) | `python -m unittest discover -s guest/tests` |
| Steam bootstrapper against Valve's live data | Parsed the real `steam_client_linuxarm64` manifest (version 1792618285); selected `steam_linuxarm64` and `bins_linuxarm64_linuxarm64` | `RealManifestFormatTests` with `IDECK_STEAM_MANIFEST` |
| ARM64 Steam client packages | Downloaded `steam_linuxarm64` (4,552,071 B) and `bins_linuxarm64_linuxarm64` (110,383,070 B); **both SHA-256 matched the manifest**; `steamrtarm64/steam` is ELF AArch64; zip entries carry no exec bits (so the bootstrapper restores them) | curl, sha256sum, Python zipfile |
| Core C API through ctypes (the path the CI boot test uses) | Built the exact desktop-test QEMU command line; `memory.plan` on 12 GiB / 6 GiB limit → **3072 MiB guest, 384 MiB TB cache**; controller packet encoding correct | `ideck_core.dll` + `tools/ideck_host.py` classes |
| Shell scripts | `bash -n` clean for all 10 scripts | Git Bash |
| Python files | `py_compile` clean | |
| Native benchmark baseline (Windows x86-64, not iPad) | int 2344 Mops/s · fp 9692 MFLOP/s · 20-thread int 16110 Mops/s (6.87×) · memcpy 4590 MB/s · read 8710 MB/s · latency 106.7 ns · ipc 9.67 Gops/s | `ideck-bench.exe` |

### Written but not compiled or run here

| Component | Why not | Where it gets verified |
|---|---|---|
| iOS app (Swift, Objective-C, XcodeGen project) | needs Xcode / the iOS SDK | `ios.yml` on a macOS runner |
| UTM sysroot fetch/build | needs macOS | `ios.yml` |
| Linux image (`linux/build-image.sh`) | needs root on arm64 Linux | `runtime.yml` on `ubuntu-24.04-arm` |
| Boot test: agent ready, virtual controller, provisioning, Steam install, benchmark in the guest, screenshots | needs the image | `runtime.yml` |
| Steam client actually starting in the guest | needs the boot test, then a device | `runtime.yml` screenshots, then iPad |
| JIT with StikDebug, Venus over MoltenVK, SPICE display, audio, controllers on iPad | needs an iPad | device |
| Any game | needs all of the above | device |

## How to add results

- **CI runs:** the `runtime.yml` boot test writes `out/boot-test/report.json`, `bench.json` and `screen-*.png` (workflow artifact). Copy the key numbers into a new section here with the run URL.
- **Device runs:** record the iPad model, iPadOS version, runtime version, app build, the self-test report (Runtime › Run Self-Test › share), the benchmark JSON (Performance › Share results) and per-game observations ([COMPATIBILITY](COMPATIBILITY.md)).
