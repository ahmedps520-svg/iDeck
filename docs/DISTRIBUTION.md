# Distribution: TestFlight vs sideload

## Verdict

| | Sideload edition (primary) | TestFlight edition |
|---|---|---|
| Signing | Development (your Apple ID, free or paid) | Distribution (paid Apple Developer account) |
| `get-task-allow` | yes, so a debugger can attach | stripped by distribution signing |
| JIT | yes, through StikDebug (debugger-assisted, TXM protocol) | **no** |
| QEMU build | TCG JIT (`sysroot-iOS-arm64`) | TCI interpreter (`sysroot-iOS-TCI-arm64`) |
| Games | the target | not realistic: the interpreter is orders of magnitude slower |
| Validity | 7 days (free Apple ID) or 1 year (paid) | 90 days per build |
| Built by | `ios.yml` → `sideload` job (unsigned IPA) | `ios.yml` → `testflight` job (needs App Store Connect API secrets) |

Why TestFlight cannot have JIT (as of November 2026):

- Executable memory needs either the `dynamic-codesigning` entitlement (Apple grants it to nobody outside its own apps), BrowserEngineKit's JIT (EU only, browsers only), or a debugger attached to a `get-task-allow` process. Distribution signing removes `get-task-allow`. (Sources are in the research notes in [ARCHITECTURE](ARCHITECTURE.md). UTM ships the same split: "UTM SE" on the App Store and TestFlight, full UTM sideloaded.)
- App Review guideline 4.7 allows emulators but grants no JIT.
- Hypervisor.framework and Virtualization.framework are macOS-only. UTM-HV uses a private entitlement through TrollStore, which iDeck does not use.

The TestFlight edition is built so that the claim can be checked rather than
assumed, and because it can still install and inspect the runtime. It is not a
gaming configuration and the app says so.

## JIT on iPadOS 26/27 (TXM devices, including M5)

iDeck uses the utmapp/qemu fork's TCG region allocator (`tcg/region.c`,
`alloc_code_gen_buffer_splitwx_vmremap`). On iOS 26+ it:

1. maps the code buffer RX,
2. creates a RW alias with `mach_vm_remap` (`split-wx=on`, set by `core/qemu_args`),
3. if the process is being traced, executes `brk #0x69` with x0=address and x1=size, so the attached debugger can make the region executable under TXM.

StikDebug implements the debugger side with its `legacy.js` script, verified
in StikDebug's source (StikDebug/StikDebug @ 0393dca):

- legacy.js attaches, continues past every stop until the first `brk #0x69`, writes to each 16 KiB page of the RX range through debugserver (which makes it usable for JIT under TXM), then detaches. It services one region per attach, and QEMU allocates one code buffer per process.
- StikDebug chooses scripts per app: first a script the user assigned (long-press › Assign Script), else an automatic match on the **app name** (e.g. "UTM" → legacy.js). For an unknown app it attaches and detaches immediately. That sets `CS_DEBUGGED` but leaves `P_TRACED` false, so QEMU skips the `brk` and JIT memory is never prepared. This is what the first device run showed.
- `universal.js` must **not** be used: it rejects `brk #0x69` and never prepares the region.

iDeck therefore:

1. requests JIT itself with StikDebug's `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=legacy.js` URL (`RuntimeController.requestJIT`);
2. refuses to start QEMU on iPadOS 26+ unless the debugger is still attached (`P_TRACED`, `IDPlatform.isTraced`), not merely `CS_DEBUGGED`;
3. continues automatically when StikDebug returns it to the foreground with the debugger attached.

Possible improvement: embed StikJIT (MPL-2.0) in an app extension, as Henge does,
so that on iPadOS 27 JIT can be enabled from inside iDeck with on-device
pairing. Not implemented.

## Entitlements

`ios/iDeck/Support/iDeck.entitlements`:

| Entitlement | Purpose | Free Apple ID |
|---|---|---|
| `get-task-allow` | debugger attach → JIT | yes (development signing) |
| `com.apple.developer.kernel.increased-memory-limit` | larger jetsam limit | yes (per Henge's signing notes) |
| `com.apple.developer.kernel.extended-virtual-addressing` | more VA for guest RAM + dual JIT mapping | **no**, so sideloaders drop it |
| `com.apple.security.application-groups` | lets virglrenderer `shm_open` Venus blob memory in the sandbox | depends on the sideloading tool: AltStore/SideStore register groups, others may not |

If the app group is missing, iDeck warns that Vulkan blob memory will fail
(UTM PR #8044 found this causes `VK_ERROR_OUT_OF_HOST_MEMORY`). OpenGL (virgl)
still works.

## Memory limits

Public measurements, none taken on an M5 iPad:

- 12 GB iPhone 17 Pro Max with the increased-memory-limit entitlement: about 6144 MB (Apple Developer Forums, thread 834805).
- 16 GB M4 iPad Pro on iPadOS 27: 5.3–6 GB available (NomadSculpt forum).

The core therefore estimates the limit as 50% of RAM with the entitlement and
37.5% without, but always prefers `os_proc_available_memory()` measured at
runtime. On a 12 GB M5 that predicts a **3 GiB guest**, with 4 GiB if the
measured limit allows. File-backed guest RAM (`memory-backend-file`, Advanced
Settings) is an experimental way to keep guest pages out of the jetsam
footprint. It is untested.

## Building without a Mac

Everything Apple-specific runs on GitHub's macOS runners ([BUILD](BUILD.md)).
You download `iDeck.ipa` from the workflow run or the release and sign and
install it from Windows with Sideloadly, or on-device with SideStore or AltStore.
