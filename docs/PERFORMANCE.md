# Performance

## Targets (from the brief; not achievements)

| | Target |
|---|---|
| Render resolution | 720p (default `1280x720`) |
| Baseline | 30 FPS where the game and compatibility layers allow |
| Stretch | 60 FPS |
| Audio | stable, with no underruns |
| Input | responsive. Controller packets travel on their own channel, outside the request path. |

**No iPad measurements exist yet.** Nothing below estimates FPS.

## What iDeck measures

| Metric | Source | Shown in |
|---|---|---|
| Game FPS, frame time | MangoHud inside Linux (Vulkan layer) | over the game (Settings › FPS overlay) |
| Guest CPU %, per core | agent `/proc/stat`, every 2 s | Performance, Runtime |
| Guest memory | agent `/proc/meminfo` | Performance |
| iDeck footprint, headroom | `task_vm_info.phys_footprint`, `os_proc_available_memory()` | Performance |
| Memory pressure and actions taken | DispatchSource memory pressure plus headroom thresholds | Performance |
| Thermal state | `ProcessInfo.thermalState` (exact temperatures are not exposed to apps) | Performance |
| Battery and drain rate | `UIDevice.batteryLevel` over time | Performance |
| GPU utilisation | **not measurable**: iPadOS exposes no API, so iDeck shows none | — |
| CPU micro-benchmarks | `ideck-bench` in the guest | Performance › CPU benchmark |

## Optimisations implemented

- **Memory:** jetsam-aware guest sizing; a bounded TCG cache; balloon with free-page reporting; on pressure the guest drops caches, the balloon inflates, disks sync and UI caches are released. Journald runs in RAM; `vm.swappiness=0`.
- **CPU:** MTTCG; the `neoverse-n1` model avoids PAuth/SVE emulation costs; performance profiles set 2, 4 or 6 vCPUs; the agent's input path runs on its own thread.
- **GPU:** zero-copy SPICE GL scanout into an MTKView; frames are presented on display refresh (`preferredFramesPerSecond = 120`) and drawn only when new.
- **Storage:** raw sparse images with `discard=unmap`, `detect-zeroes=unmap`, `aio=threads`; no qcow2 overhead; APFS clones for snapshots.
- **Background work:** apt/man/fstrim timers are masked, and no desktop environment runs.
- **Thermal:** the profile is user-selectable. Automatic throttling based on `thermalState` is a planned extension, not implemented.

## Host baseline (measured in this session)

`ideck-bench` built natively for Windows x86-64 and run on the development PC
(Intel Core i5-14600K, 20 threads). This **is not iPad data**; it is the native
reference point for the same code.

| Benchmark | Result |
|---|---|
| int_single | 2344 Mops/s |
| fp_single (384×384 matmul) | 9692 MFLOP/s |
| int_multi (20 threads) | 16110 Mops/s (6.87× single) |
| mem_bandwidth (memcpy 64 MiB) | 4590 MB/s |
| mem_read | 8710 MB/s |
| mem_latency (random, 64 MiB) | 106.7 ns |
| ipc | 9.67 Gops/s |
| syscall, jit_translate | not measured on Windows |

The CI boot test runs the same benchmark inside the guest under QEMU TCG on an
arm64 GitHub runner (`out/boot-test/bench.json`). Those numbers describe TCG on a
Neoverse server core, not an M5. A device run is needed for real iPad figures.

## Benchmark plan for games

Measure separately at 720p:

1. **2D:** a native ARM64 or GL title
2. **Moderate 3D:** an older D3D9/GL title
3. **Demanding 3D:** a recent D3D11/12 title

For each, record average FPS, 1% lows (MangoHud), guest CPU %, iDeck footprint,
thermal state after 30 minutes, and battery drain. Write results to
[TEST_RESULTS](TEST_RESULTS.md) and `compat.json`.
