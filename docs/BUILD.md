# Building iDeck

Three products, three pipelines. None of them needs a Mac on your desk.

| Product | Where it builds | Workflow |
|---|---|---|
| Core, agent and benchmark tests | Windows/Linux/macOS (local or CI) | `.github/workflows/ci.yml` |
| Linux runtime (kernel, initrd, system disk, manifest) | GitHub `ubuntu-24.04-arm` | `.github/workflows/runtime.yml` |
| iOS app (IPA / TestFlight) | GitHub macOS runner (Xcode 26+) | `.github/workflows/ios.yml` |

## 1. Core and guest binaries (local, any OS)

Needs Python 3.10+. The C/C++ toolchain is Zig's clang, installed with pip:

```bash
python -m venv .venv
.venv/Scripts/python -m pip install ziglang==0.14.1    # Windows; use .venv/bin/python elsewhere
.venv/Scripts/python tools/build_core.py test           # core unit tests
.venv/Scripts/python tools/build_core.py agent          # agent unit tests
.venv/Scripts/python tools/build_core.py all --target aarch64-linux-musl   # guest binaries
.venv/Scripts/python -m unittest discover -s guest/tests                   # Python tests
```

Outputs go to `build/core/`: `ideck-agent-aarch64-linux-musl` and
`ideck-bench-aarch64-linux-musl` (static binaries for the guest), plus
`libideck_core` (`lib` target) for the CI host test.

CMake also works (`cmake -S core -B build/cmake && ctest --test-dir build/cmake`),
which CI uses to check the core with AppleClang.

## 2. Linux runtime

Run **Actions → Linux runtime → Run workflow** and choose a version such as `0.1.0`.
With *publish* ticked, the workflow:

1. builds the agent and benchmark (aarch64, static musl),
2. runs `linux/build-image.sh` as root on the arm64 runner: mmdebstrap Debian 13 `minbase` plus `linux/packages.txt`, Mesa from `trixie-backports`, the iDeck overlay, then a sparse ext4 `system.img` via `mke2fs -d`,
3. boot-tests the image with `tools/ideck_host.py` (QEMU TCG): agent ready, virtual controller, provisioning with the Steam client install, benchmark, screenshots, self-test,
4. compresses everything with xz and writes `manifest.json` (SHA-256 of both the download and the installed file),
5. publishes release `runtime-<version>` and updates `runtime-latest/manifest.json`, which is the URL the app reads.

For a reproducible build, pass `--snapshot 20261110T000000Z` to `build-image.sh`
to pin snapshot.debian.org. Every build records exact package versions in
`packages.lock`.

## 3. iOS app

Run **Actions → iOS app → Run workflow** with edition `sideload`.

1. `ios/scripts/fetch_sysroot.sh ios` provides UTM 5.0.8's iOS dependency sysroot (QEMU 10.0.12-utm, virglrenderer with Venus, MoltenVK, ANGLE, spice-gtk, GLib, GStreamer). It first tries UTM's published release-build artifact. Otherwise it builds the sysroot from source with UTM's `build_dependencies.sh` at the pinned commit (1.5–3 h, cached afterwards).
2. `gen_sysroot_xcconfig.sh` writes the link flags. `xcodegen generate` creates `ios/iDeck.xcodeproj` from `ios/project.yml`.
3. `xcodebuild archive` runs with signing disabled. A build phase embeds all sysroot frameworks (QEMU is loaded with `dlopen` at runtime), QEMU's data files and the Vulkan ICD manifests.
4. `package_ipa.sh` produces `iDeck.ipa`, which is uploaded as an artifact (and as a release asset for `v*` tags).

The app reads its runtime from
`https://github.com/<your repo>/releases/download/runtime-latest/manifest.json`,
which is baked in at build time. It can be changed in Settings › Advanced.

### TestFlight

Choose edition `testflight` or `both`. Add these repository secrets: `ASC_KEY_ID`,
`ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (base64 of the App Store Connect API
`.p8`) and `APPLE_TEAM_ID`. The job builds the `iDeckTF` target against the TCI
sysroot, signs automatically and uploads. Secrets are only written to a temp
file that is deleted afterwards and are never echoed. Read
[DISTRIBUTION](DISTRIBUTION.md) first: this edition has no JIT.

### Runner image

UTM 5's sysroot targets the iOS 26 SDK, so the jobs use `macos-26` with the
newest installed Xcode. If your account has a different label, set the
repository variable `IDECK_MACOS_RUNNER`.

## Versioning

- App: `MARKETING_VERSION` in `ios/project.yml`. The build number is the workflow run number.
- Runtime: the workflow input or tag `runtime-X.Y.Z`. The manifest's `min_app_build` blocks too-old apps.
- Core: `ideck_core_version()`.
