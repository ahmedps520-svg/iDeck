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

## Session 2: 2026-11-11, GitHub Actions (repo `ahmedps520-svg/iDeck`)

### CI (`ci.yml`, commit `cbcae63`): all 8 jobs green

Core and agent tests on Windows 2025, Ubuntu 24.04 x64, Ubuntu 24.04 arm64
and macOS 15; core built with AppleClang/CMake; arm64 test binaries and
`ideck-bench --quick` run under qemu-user; shellcheck and `py_compile` lint.
On arm64 Linux this includes the uinput mapping test and the POSIX
end-to-end Steam bootstrap test that are skipped on Windows.

### Linux runtime 0.1.1 boot test (`runtime.yml` run 42999579844, `ubuntu-24.04-arm`, QEMU 8.2 TCG, `-cpu neoverse-n1`, 4 vCPU, 4 GiB)

Not an iPad: this is the same image and agent protocol under TCG on a GitHub
arm64 server core, with no GPU passthrough (`desktop-test` profile).

| Check | Result |
|---|---|
| Image build (mmdebstrap Debian 13 + backports Mesa 26.1.6, kernel 6.12.116) | ✓ about 75 s |
| Boot to agent `ready` | ✓ **34.4 s** |
| Virtual controller from a host packet | ✓ `Microsoft X-Box 360 pad (iDeck 1)` appeared in `/proc/bus/input/devices` |
| Provisioning: Steam ARM64 client bootstrap | ✓ 2 packages, manifest 1792618285, `steamrtarm64/steam` installed |
| Provisioning: FEX RootFS | ✓ Ubuntu 24.04 EroFS downloaded, hash-checked, mounted at `/usr/share/guestos/fex-mesa` |
| Self-test | 14/16. **Failed: opengl and vulkan → llvmpipe** (expected, because the CI profile has no virgl/Venus). Passed: 4 KiB pages, LSE, LRCPC, library disk (ext4 formatted on first boot), DNS, DRM render node, uinput, agent, Steam binary, FEX RootFS, user namespaces |
| Audio | reported "ok" with sink `auto_null`, which is PipeWire's dummy sink (the CI profile has no sound device). The self-test was then fixed to fail on `auto_null`. |
| Steam service | ✓ `ideck-steam` active with Steam processes; the PIDs changed during the run (a self-update restart) |
| Steam window | **not seen** within about 6 minutes of screenshots (the X session background only). The next boot test waits up to 60 minutes and saves Steam's journal. |
| Clean shutdown via agent | ✓ QEMU exit 0 |

Guest CPU benchmark (`ideck-bench`, inside the TCG guest on the runner):

| Benchmark | Result |
|---|---|
| int_single | 2698 Mops/s |
| fp_single | 220 MFLOP/s |
| int_multi (4 vCPU) | 10171 Mops/s (3.77×) |
| mem_bandwidth (memcpy) | 366 MB/s |
| mem_read | 3702 MB/s |
| mem_latency | 523 ns |
| syscall | 25.4 µs |
| ipc | 2.16 Gops/s |
| jit_translate | 14.1 µs per block (warm 0.37 µs) |

What this tells us: integer code translates well. Floating point, memcpy and
syscalls are the TCG bottlenecks (soft-float helpers, byte-wise memory
helpers, full exception round trips). The iPad's M5 will have different
absolute numbers.

### iOS app builds (`ios.yml`)

| Attempt | Result | Fix |
|---|---|---|
| 1 | 9 Swift errors in 3 files | `NS_SWIFT_NAME` for IDSpiceClient (Swift had renamed `sendMouseButton` to `send`); `StatTile` argument order |
| 2 | all sources compiled; link: GStreamer static libs not found | `$(SYSROOT_DIR)`-based paths in the generated xcconfig |
| 3 | link: `framework 'Compression' not found` | link `libcompression.tbd` |
| 4 | link: `GLESv2` "not an allowed client" | skip frameworks with `LC_SUB_CLIENT` when generating link flags |

## How to add results

- **CI runs:** the `runtime.yml` boot test writes `out/boot-test/report.json`, `bench.json` and `screen-*.png` (workflow artifact). Copy the key numbers into a new section here with the run URL.
- **Device runs:** record the iPad model, iPadOS version, runtime version, app build, the self-test report (Runtime › Run Self-Test › share), the benchmark JSON (Performance › Share results) and per-game observations ([COMPATIBILITY](COMPATIBILITY.md)).
