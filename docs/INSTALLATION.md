# Installing iDeck on an iPad

Target: iPad Pro M5 on iPadOS 27. Any iPad with an M-series chip and 8 GB or
more of RAM should behave similarly.

## You need

- the `iDeck.ipa` from the **iOS app** workflow (artifact or release),
- a published runtime (**Linux runtime** workflow with *publish*),
- a Windows PC with **Sideloadly**, or **SideStore/AltStore** on the iPad,
- **StikDebug** 3.1.12 or later on the iPad, with a pairing file and LocalDevVPN set up as its README describes (needed for JIT on iPadOS 26+),
- about 40 GB free: roughly 2 GB for the runtime, plus the game library, which starts at 24 GB logical size and only uses what Linux writes.

## 1. Sign and install

**Sideloadly (Windows):** drag `iDeck.ipa` in and sign with your Apple ID. A free
account works for 7 days, then re-sign. Install over USB.

**SideStore / AltStore:** add the IPA. These tools register the app group that
Vulkan needs. If your tool does not, the self-test reports Vulkan as failing and
OpenGL still works.

The IPA must be **development-signed** (these tools do that), because that keeps
`get-task-allow`, which JIT needs.

## 2. Enable JIT

Open StikDebug, tap **Enable JIT** and choose iDeck. iDeck uses the same JIT
protocol as UTM; if StikDebug asks for a script, choose the legacy (UTM) script.
iDeck opens with JIT active. You need to do this each time you launch iDeck.

## 3. Run setup

Tap **Install iDeck**. The steps, in order:

| Step | What happens |
|---|---|
| Check device / storage / distribution | Reports the model, RAM, free space, signing, JIT, app group and memory entitlement |
| Fetch manifest | Downloads and validates the runtime manifest |
| Download runtime | Resumable HTTPS download, about 1 GB. It can be paused, and it continues after the app is closed. |
| Verify | SHA-256 of every file |
| Install runtime | Streams the xz decompression into sparse files and checks the decompressed hash |
| Create storage | Sparse game library disk |
| Start Linux | First boot takes a few minutes under emulation |
| Install Steam | Linux downloads Valve's ARM64 Steam client and verifies each package |
| Compatibility tools | Downloads the FEX x86-64 RootFS (for x86 Linux games) |
| Graphics, audio, controllers, self-test | Checks virgl, Venus, PipeWire and uinput |

If a step fails, the error is shown and **Continue Setup** retries from that
step. Completed steps are not redone.

## 4. Play

Tap **Start Gaming**. Steam opens. Sign in, including Steam Guard. Install a game
and press Play. Use **Library** in iDeck for artwork and one-tap launch.

## Updating

When a new runtime is published, re-run setup from **Runtime › Repair Setup**.
Runtime updates replace only the system disk. Steam, games and saves are on
the library disk and are kept. **Roll Back Runtime** switches to the previous
version.
