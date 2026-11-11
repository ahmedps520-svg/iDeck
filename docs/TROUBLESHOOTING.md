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
| Black screen, app closes when booting | Jetsam: the memory limit was exceeded | Settings › Linux memory: try 3 GB or 2 GB, or the Battery Saver profile. Check Runtime › Memory plan notes. (The earlier experiment's black screen at 3072 MB is consistent with this or with the old iOS hostmem BAR bug fixed in UTM 5.0.5; not verified.) |
| "Vulkan is off for this session: iPadOS refused GPU shared memory" (log: `signature: app groups []`, `shm_open(...) failed: Operation not permitted`) | The signing tool removed the app group. Venus blob memory is POSIX shared memory that iPadOS only allows under an app group in the code signature. | OpenGL and the Steam client still work. For Vulkan, re-sign with a tool that keeps app groups. The log's `signature:` line shows what the signature carries. |
| Self-test: vulkan warning, "llvmpipe" | Venus unavailable (see above) | Optional since runtime 0.1.4: setup continues. |
| "JIT was enabled N seconds ago…" / iDeck closed with SIGTRAP in `tcg_region_init` | StikDebug attached long before Linux started (e.g. during a runtime download) and no longer answered QEMU's JIT request | Close iDeck from the app switcher, enable JIT again in StikDebug, then continue. Since build 17 iDeck asks for this instead of crashing. |
| Self-test: opengl shows llvmpipe | virgl not active | Check the QEMU log for `virtio-gpu-gl`/ANGLE errors. Reinstall the IPA (embedded frameworks). |
| Steam window blank or crashes (CEF) | steamwebhelper GPU path | Settings › Software-rendered Steam UI, then Runtime › Restart Steam |
| Steam stuck updating | First update under emulation is slow | Wait. Progress is visible in the Steam window. |
| Steam bootstrap failed | Valve changed CDN packages, or a network problem | Runtime › Repair Setup. Share the provision log (Runtime › Console log). |
| Controller not detected in a game | Game expects a different pad | Enable Steam Input for the game. iDeck pads appear as Xbox 360 controllers. |
| No rumble | Game uses no FF_RUMBLE, or vibration is off | Controls › Controller vibration |
| Mouse-look spins or does nothing | Pointer not captured | In-game menu › Capture Mouse |
| No sound | Audio off, or PipeWire not running | Settings › Game audio. Self-test `audio` check. |
| Clock wrong in Linux after resuming | VM paused in background | Fixed automatically by `time.sync` on return. Otherwise restart Steam. |
| Library disk full | Growth needs more free space on the iPad | Free iPad storage. iDeck keeps 8 GB free for iPadOS and grows the library when space allows. |

## Logs

- **QEMU log** (`tmp/ideck/qemu.log`): QEMU errors, virglrenderer, ANGLE and MoltenVK messages.
- **Console log** (`tmp/ideck/console.log`): kernel and systemd serial console.
- **Guest logs:** agent `logs` operation for `ideck-*` units, shown in Runtime.

All of these can be shared from Runtime or Settings › Diagnostics.
