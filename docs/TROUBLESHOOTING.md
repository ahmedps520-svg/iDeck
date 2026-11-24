# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Enable JIT to start Linux" | iDeck was opened without a debugger attached | Tap **Enable JIT with StikDebug** in iDeck, or enable JIT for iDeck in StikDebug each launch. Check that LocalDevVPN is on and the pairing file is valid. Use StikDebug ≥ 3.1.12 on iPadOS 26.4+. |
| "JIT was enabled, but StikDebug detached right away" (Diagnostics: CS_DEBUGGED yes, debugger attached no) | StikDebug ran no script for iDeck (it auto-assigns scripts by app name and does not know iDeck) | Use the in-app button (it requests legacy.js), or in StikDebug long-press iDeck › Assign Script › legacy.js. Never assign universal.js. |
| QEMU log: `Property 'virtio-gpu-gl-pci.refresh_rate' not found` | Builds 1–9 passed an option this QEMU lacks | Install build 10 or later |
| StikDebug cannot find iDeck | IPA not development-signed | Re-sign with Sideloadly, AltStore or SideStore (they keep `get-task-allow`) |
| "Restart iDeck" after Linux stopped | QEMU starts once per app launch | Close iDeck from the app switcher, enable JIT, then open it again |
| Setup: "No runtime source is configured" | IPA built without a manifest URL | Settings › Advanced › Runtime manifest URL, e.g. `https://github.com/<you>/<repo>/releases/download/runtime-latest/manifest.json` |
| Setup stops at verify | Corrupt or incomplete download | Retry. The bad file is deleted and downloaded again. |
| Setup: not enough storage | Fewer than about 12 GB free, or less than the manifest needs | Free space, then Continue Setup |
| Setup: "iOS lets iDeck use N MiB of memory on this iPhone…" (build 27+) | The per-app memory limit iOS sets on this device is below what the smallest Linux (2 GB) plus iDeck needs. Setup checks it before downloading anything. | None in iDeck: the limit comes from iOS. Share `ideck.log` (the `setup:` line has the numbers). |
| Home: "iDeck stops opening in …" (build 27+) | The provisioning profile from Sideloadly/AltStore/SideStore runs out (7 days with a free Apple ID). The notice appears 2 days before. | Install iDeck again over the existing app with the same Apple ID (or refresh it in AltStore/SideStore). This keeps the app's data. The expiry date is also in Diagnostics › Signing. |
| Steam's window black, grey or flickering after turning on **GPU-drawn Steam UI** (build 34+, experimental) | Chromium's GPU path through Zink/Venus does not work on this device or iPadOS yet | Turn the setting off; Steam restarts with the software UI. Send `ideck.log` and `linux-steam.log` so the GPU path can be fixed. |
| SideStore: "undeclared permissions", "mismatched version" or "hash" error when installing from the iDeck feed | The feed and the IPA disagree. CI checks this after every publish, so a mismatch means the release asset was replaced by hand. | Run the iOS workflow again with *publish*. It rewrites the feed from the IPA. |
| SideStore installs iDeck, but the old iDeck (Sideloadly) is still there with its data | SideStore signs it as `com.ideck.app.<team ID>`, a separate app | Expected. Keep the copy whose Linux and games you want; a free Apple ID allows only 3 sideloaded apps. |
| Only a small Steam updater window (grey, unpainted windows around it) for minutes | Steam is installing a client update (574 MB on 2026-11-12); under emulation extraction alone took about 5 min in CI. Until runtime 0.1.9 the setup deleted Steam's package files, so Steam's first update after setup downloaded the whole client. | Keep iDeck open and on screen. Build 26+ shows the progress over the display. If iDeck is closed mid-update, Steam starts the update again. |
| Home: "The last session ended unexpectedly" | iDeck ended while Linux was running. The notice says whether it crashed (signal in `crash.log`) or ended without a signal (iOS memory or watchdog kill, the app switcher, or StikDebug launching iDeck again) | Share the logs from Diagnostics. Also share any `iDeck-…` or `JetsamEvent-…` file from the same minute, found in Settings › Privacy & Security › Analytics & Improvements › Analytics Data. While Linux is running, do not open iDeck from StikDebug again: it can start a new copy of iDeck. |
| Black screen, app closes when booting | Jetsam: the memory limit was exceeded | Settings › Linux memory: try 3 GB or 2 GB, or the Battery Saver profile. Check Runtime › Memory plan notes. (The earlier experiment's black screen at 3072 MB is consistent with this or with the old iOS hostmem BAR bug fixed in UTM 5.0.5; not verified.) |
| Log `signature: ... GPU shared memory file-backed fallback` | Normal with free Apple ID signing: there is no app group, so Venus blob memory comes from files in tmp/ (build 24+) | Nothing to do. `gpu shm:` lines show how many allocations used files. |
| Self-test: "vulkan: warning (no device)"; `qemu.log`: `APP_SANDBOX_GROUP_ID is 30 chars, at most 28 fit` | Build 30 or earlier signed by a tool that names the app group `<bundle id>.<team ID>` (iloader, SideStore): the 30-character name was passed to virglrenderer, which refuses it before the shared-memory fallback can run | Install build 31 or later: it passes the short `group.ideck` to the fallback. The `vulkan: on` line in `ideck.log` names it. |
| "Vulkan is off for this session: no GPU shared memory" | Both the app-group shared memory and the file fallback failed. The reason is in the message and on the `signature:` log line. | OpenGL and the Steam client still work. Share `ideck.log`. |
| Self-test: vulkan warning, "llvmpipe" | Venus unavailable (see above) | Optional since runtime 0.1.4: setup continues. |
| "JIT was enabled N seconds ago…" / iDeck closed with SIGTRAP in `tcg_region_init` | StikDebug attached long before Linux started (e.g. during a runtime download) and no longer answered QEMU's JIT request | Close iDeck from the app switcher, enable JIT again in StikDebug, then continue. Since build 17 iDeck asks for this instead of crashing. |
| Self-test: opengl shows llvmpipe | virgl not active | Check the QEMU log for `virtio-gpu-gl`/ANGLE errors. Reinstall the IPA (embedded frameworks). |
| Steam window blank or crashes (CEF) | steamwebhelper GPU path | Settings › Software-rendered Steam UI (on by default since build 24). Steam restarts by itself. |
| Linux screen is empty (no Steam window), e.g. after closing a game (build 29+) | Steam's windows are minimised while it is not on screen, and the app shows them again when a game ends | Tap ⋯ › Show Steam. Settings › Steam › "Pause Steam's window when it is not on screen" turns this off. |
| Steam slow or heavy with no game open | The Steam UI is a Chromium app running on an emulated CPU | Settings › Lightweight Steam and Compact library (Small Mode). In Steam: turn off Shader Pre-Caching, the Steam Overlay and smooth scrolling, and turn on Library › Low Performance Mode. Use Battery Saver or 540p on an iPhone if it gets hot. |
| Text too small on iPhone | 1280×720 Linux display on a phone screen | Pinch to zoom; two fingers move the zoomed view; ⋯ › Reset Zoom |
| Steam stuck updating | First update under emulation is slow | Wait. Progress is visible in the Steam window. |
| Steam bootstrap failed | Valve changed CDN packages, or a network problem | Runtime › Repair Setup. Share the provision log (Runtime › Console log). |
| Controller not detected in a game | Game expects a different pad | Enable Steam Input for the game. iDeck pads appear as Xbox 360 controllers. |
| No rumble | Game uses no FF_RUMBLE, or vibration is off | Controls › Controller vibration |
| In a game, a tap makes the cursor jump instead of clicking | The game reads mouse movement, not positions | ⋯ menu › Pointer: trackpad (automatic picks it while a game runs, build 42): drag to move, tap to click |
| In a game with a normal pointer, taps no longer land where you tap | Trackpad pointer is active | ⋯ menu › Pointer: touch |
| No sound | Audio off, or PipeWire not running | Settings › Game audio. Self-test `audio` check. |
| Clock wrong in Linux after resuming | VM paused in background | Fixed automatically by `time.sync` on return. Otherwise restart Steam. |
| Library disk full | Growth needs more free space on the iPad | Free iPad storage. iDeck keeps 8 GB free for iPadOS and grows the library when space allows. |

## Logs

- **QEMU log** (`tmp/ideck/qemu.log`): QEMU errors, virglrenderer, ANGLE and MoltenVK messages.
- **Console log** (`tmp/ideck/console.log`): kernel and systemd serial console.
- **Guest logs:** agent `logs` operation for `ideck-*` units, shown in Runtime.

All of these can be shared from Runtime or Settings › Diagnostics.
