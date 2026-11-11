# Graphics

## Pipeline

```
Game (Vulkan / OpenGL / D3D via DXVK/VKD3D-Proton)
  └─ guest Mesa: Venus (Vulkan) | virgl (OpenGL)        ← Debian trixie-backports Mesa
       └─ virtio-gpu (blob + context init), virtio-serial-free command streams
            └─ QEMU virtio-gpu-gl-pci,blob=true,venus=true,hostmem=…   (utmapp/qemu 10.0.12)
                 └─ virglrenderer (utmapp fork, render server in a THREAD — iOS cannot fork)
                      ├─ Venus → Vulkan loader → MoltenVK (UTM build) → Metal
                      └─ virgl → libepoxy/EGL → ANGLE (Metal backend) → Metal
                           └─ Apple M5 GPU
Scanout: GL texture → SPICE gl=on → CocoaSpice → MTKView (no CPU copy)
```

Nothing here is software rendering. If the guest falls back to llvmpipe, the
self-test reports `opengl`/`vulkan` as **failed** rather than accelerated.

## Required configuration (set by iDeck)

- **QEMU device:** `virtio-gpu-gl-pci,xres=1280,yres=720,blob=true,venus=true,hostmem=<plan>M,refresh_rate=60000`. `hostmem` is guest-visible address space for mapping Venus blobs, not RAM. The planner uses 2–4 GiB. UTM 5.0.5 fixed an iOS BAR bug that previously forced 256 MiB.
- **Environment:**
  - `ANGLE_DEFAULT_PLATFORM=metal`
  - `VK_DRIVER_FILES=<app>/vulkan/icd.d/MoltenVK_icd.json`
  - `APP_SANDBOX_GROUP_ID=<app group>`: virglrenderer's `shm_open` for blob memory is only allowed under the app group prefix in the sandbox. Without it, Venus fails with `VK_ERROR_OUT_OF_HOST_MEMORY`. This is the most likely cause of the shared-memory failure seen in the earlier experiment.
- **Guest:** Xorg modesetting with glamor (GL through virgl). Vulkan compositing of the desktop is avoided because UTM reports it broken (no indirect draws for geometry shaders on Metal).

## Capability limits (researched November 2026)

| Layer | Status | Consequence |
|---|---|---|
| Venus guest driver | Advertises Vulkan 1.3/1.4, capped by the host | — |
| MoltenVK 1.4.x | Non-conformant Vulkan 1.4 subset. No upstream geometry shaders or transform feedback (UTM's build adds geometry shaders). Missing `robustBufferAccess2`/`nullDescriptor`. | DXVK 3.x (Vulkan 1.4 + transform feedback) cannot fully initialise. VKD3D-Proton (Vulkan 1.3, 1M descriptors) is likely limited. |
| KosmicKrisp | Vulkan 1.4 conformant on macOS. iOS build experimental (UTM ships it for iOS 26+). Lacks geometry shaders and crashes Venus with optimal-tiled images. | Kept as an option to try, not the default |
| virgl GL | GL 2.1–4.3 to the guest via ANGLE (GLES host) | Steam's CEF UI and GL games work. Older GL games are the most likely to run. |

UTM reported DXVK working with "a lot of visual issues" through Venus with its
patched MoltenVK on macOS (UTM issue #7575). iDeck makes no claim about DirectX
until it is tested on device.

## What would help next

- Pin DXVK 2.7 (Vulkan 1.3) for D3D9–11 titles through Steam launch options.
- Adopt UTM's Neptune/DXMT D3D11 passthrough, which bypasses the missing Vulkan features. UTM ships it for iOS.

## Measuring

`self_test.py` records the GL renderer string and Vulkan `deviceName`/`apiVersion`,
shown under Runtime › Self-test. In-game FPS comes from MangoHud (Settings ›
FPS overlay). There are no benchmark numbers from an iPad yet.
