# Compatibility

## Database

`ios/iDeck/Resources/compat.json` holds the tested-games database, read by the
app (Library › game › Compatibility) and validated by `core/src/compat.cpp`.
**It currently contains no entries, because no game has been tested on an iPad
yet.** Every game shows *Untested*.

The core enforces provenance: any status above `untested` must carry
`tested_at` and `runtime_version`, or the database is rejected.

```json
{
  "schema": 1,
  "games": [
    {
      "appid": 0,
      "name": "Game name",
      "path": "native-arm64 | linux-x86 | windows",
      "status": "untested | broken | boots | menus | playable | verified",
      "fps_avg": 0,
      "resolution_h": 720,
      "runtime_version": "0.1.0",
      "tested_at": "YYYY-MM-DD",
      "tester": "who",
      "notes": "what was observed",
      "launch_options": {"PROTON_USE_WINED3D": "1"}
    }
  ]
}
```

| Status | Meaning |
|---|---|
| broken | does not start, or crashes |
| boots | starts, does not reach a menu |
| menus | menus work, gameplay does not (or under 10 FPS) |
| playable | completes gameplay at 20 FPS or more with working input and audio |
| verified | playable at 30 FPS or more for a 30-minute session, with saves persisting across an iDeck restart |

## How to test a game (record real results only)

1. Note the runtime version (Runtime screen) and the iPad model.
2. Turn on the MangoHud overlay (Settings) and play for 10 or more minutes at 720p.
3. Record the status, average FPS, path (native / FEX / Proton), and any launch options needed.
4. Add the entry with a pull request. CI validates the file.

## Expected limits (not test results)

| Category | Expectation | Reason |
|---|---|---|
| Kernel anti-cheat (EAC/BattlEye without Proton opt-in, Vanguard, …) | Will not run | Unsupported on Linux and on ARM |
| D3D11/12 titles needing DXVK 3.x / VKD3D | Many will fail to render | Vulkan-on-Metal gaps ([GRAPHICS](GRAPHICS.md)) |
| Heavy CPU-bound x86 games | Very low FPS | Two translation layers ([CPU_ENGINE](CPU_ENGINE.md)) |
| Native ARM64 Linux and older GL titles | Best chance | One translation layer, virgl GL |
| Games needing more than 4 GB RAM | Likely to fail | Guest RAM planned at 3–4 GiB under iPadOS limits |

These are engineering expectations, not measurements, and must not be copied
into `compat.json`.
