# Steam integration

## Which client

iDeck runs Valve's **native ARM64 Linux Steam client** (`linuxarm64`), not x86
Steam under emulation and not a web wrapper.

Facts checked on 2026-11-11:

- The client manifest is public: `https://client-update.steamstatic.com/steam_client_linuxarm64` (stable) and `steam_client_publicbeta_linuxarm64`. iDeck fetched the stable manifest (version `1792618285`, 35 packages, each with `file`, `size` and `sha2`).
- `bins_linuxarm64_linuxarm64` (110,383,070 bytes) was downloaded and its SHA-256 matched the manifest (`a77faaf1…5b85a1`). It contains `steamrtarm64/steam`, an AArch64 ELF, plus `steamclient.so`, `steamwebhelper` and the rest of the client. The zip stores no Unix exec bits.
- `steam_linuxarm64` (the package marked `IsBootstrapperPackage`, 4,552,071 bytes, hash matched) contains the generic `steam.sh` and an i386 `ubuntu12_32/steam`. The ARM64 binaries are only in the `*linuxarm64*` packages.
- Valve's position (steam-for-linux issue #13745, Oct 2026): ARM Linux is not supported. The packages exist for Steam Frame. The CDN layout may change. This is the main external risk to iDeck.

## Bootstrap (`guest/rootfs/usr/lib/ideck/steam_bootstrap.py`)

1. Fetch the manifest and parse KeyValues (with a tested parser).
2. Install the full package set (34 packages; the Android package is downloaded but not extracted). The bootstrapper `steam_linuxarm64` goes first and `bins_linuxarm64_linuxarm64` (client binaries) last. With only those two, the client reported "Nothing to do" and never fetched CEF, SDL3 or the codecs (runtime 0.1.2 boot test).
3. Download each over HTTPS with Range resume, check the size and SHA-256 from the manifest, and reject zip entries that escape the Steam root or would be written through a symlink. A retry keeps the packages the failed run already extracted (same client version, in install order).
   - **Package files are kept for the client (runtime 0.1.9+).** Most packages list a compressed copy next to the plain zip: `zipvz` (`<name>.zip.vz.<sha1>_<size>`) and `sha2vz`. The bootstrap downloads that copy, checks `sha2vz`, decodes it and keeps it in `Steam/package/`. Packages without one (for example `strings_en_all`, `sdl3_steamrt_linuxarm64` on 2026-11-12) keep their plain zip there instead.
   - **Why:** the client's updater checks exactly these names. On the device (2026-11-12) it logged "Package file … missing or incorrect size" for every package, then downloaded 574,010 KB and extracted the whole client again. That happened because the bootstrap had deleted its downloads. With the files present, the first start after setup should find nothing to download, and an update should fetch only the packages whose file name (that is, content hash) changed. Not yet verified: the boot test reports what the updater did (`steam_updater` in `report.json`).
   - **VZ format,** checked against Valve's CDN files: `VZa`, a 4-byte stamp, 5 LZMA properties, LZMA data ending in an end marker, then the CRC-32 and size of the decoded data and `zv`. The decoded data is a zip with the same files as the plain zip, stored without compression. CI downloads the smallest VZ package and its plain zip from Valve and compares every file (`test_real_vz_package_matches_plain_zip`).
   - Package files from other client versions are removed. The client's own files in `package/` (metrics, host list, `beta`) are left alone.
4. Restore exec bits for ELF files and scripts.
5. Create `~/.steam/{steam,root,sdkarm64}`. The ARM64 client lives in `steamrtarm64/`. The same manifest also ships `steamrt64/` (x86-64: `steamrt64/steam` is an x86-64 ELF, checked from the package) and `steamrt32/` (x86), the client side of `steamclient.so` for x86 games under FEX. Runtimes up to 0.1.3 linked `steamrt64 → steamrtarm64` and set `.steam-enable-steamrt64-client`. A full install then failed ("steamrt64 exists and is a directory", runtime 0.1.3 boot test), and over an existing link it would have written x86-64 files into `steamrtarm64/`. The bootstrap now removes such a link together with `steamrtarm64/` (reinstalled from the packages) and removes the flag, because `steam.sh` would then start the x86-64 `steamrt64/steam`. A full install counts as complete only when `steamrtarm64/steam` is an AArch64 ELF.
6. Launch `LD_LIBRARY_PATH=$STEAMROOT/steamrtarm64 $STEAMROOT/steamrtarm64/steam -noverifyfiles` (the published community recipe). From then on the client updates itself, verified by Valve's own updater. When Valve publishes a new client version, the updater downloads the changed packages and restarts the client.

Optional switches (Settings): Big Picture (`-gamepadui`), public beta, and
software-rendered Steam UI (`-cef-disable-gpu`).

## Sign-in

You sign in inside the real Steam window, with Steam Guard (mobile app or email
code) as usual. iDeck never sees credentials. It only reads the client's local
files for the library view (`steam_library.py`).

## Library, downloads, launch

- **Library and downloads** come from `appmanifest_*.acf` (state flags, bytes downloaded/to download, size), `libraryfolders.vdf` and `localconfig.vdf` (last played). Artwork comes from Steam's public CDN by app ID.
- **Play** sends `steam://rungameid/<appid>` and **Install** sends `steam://install/<appid>` to the running client. The agent only accepts an allow-list of `steam://` commands.
- **Pause/resume** happens in Steam's Downloads page, because Steam has no CLI for it. iDeck shows progress, speed and ETA.

## Compatibility layers

- **x86-64 Linux games:** Steam's ARM64 client runs them through its FEX tool, which expects an x86 RootFS at `/usr/share/guestos/fex-mesa`. Provisioning downloads FEX's official Ubuntu 24.04 EroFS image (URL and hash pinned at image build from `rootfs.fex-emu.gg/RootFS_links.json`), verifies it and loop-mounts it from the library disk.
- **Windows games:** Steam installs **Proton ARM64** (Proton 11 has FEX for arm64ec) when you choose it. The Proton README notes that ARM64 Proton cannot be used from x86 Steam under FEX, which is why the native client matters.
- Steam Linux Runtime 4 arm64 (`SteamLinuxRuntime_4-arm64`) containers need unprivileged user namespaces, which the image enables and the self-test checks.

## Requirements the guest provides

glibc ≥ 2.31 (trixie: 2.41), kernel ≥ 5.6 (6.12), user and mount namespaces,
a D-Bus session bus, X11, pipewire-pulse, Mesa GL/Vulkan, 4 KiB pages, and
LSE atomics (neoverse-n1 CPU model).
