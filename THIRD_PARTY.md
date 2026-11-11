# Third-party components

iDeck's own source code (this repository) is MIT licensed. Built artifacts
include or download the components below under their own licenses. iDeck
does not copy source code from them; it builds, links or downloads them.

## Bundled in the iOS app (from UTM 5.0.8's dependency build, `ios/scripts/fetch_sysroot.sh`)

| Component | License | Source |
|---|---|---|
| QEMU 10.0.12 (utmapp fork) | GPL-2.0 (some parts LGPL/BSD) | https://github.com/utmapp/qemu (tag v10.0.12-utm) |
| virglrenderer (utmapp fork, Venus) | MIT | https://github.com/utmapp/virglrenderer |
| MoltenVK (utmapp fork) | Apache-2.0 | https://github.com/utmapp/MoltenVK |
| ANGLE (from utmapp/WebKit) | BSD-3-Clause | https://github.com/utmapp/WebKit |
| libepoxy | MIT | https://github.com/utmapp/libepoxy |
| spice-gtk / spice-client-glib, spice-server, phodav | LGPL-2.1+ | https://www.spice-space.org |
| GLib, json-glib, libsoup | LGPL-2.1+ | https://gitlab.gnome.org |
| GStreamer and plugins | LGPL-2.1+ | https://gstreamer.freedesktop.org |
| pixman, libpng, libjpeg-turbo, opus, gettext/intl, iconv, libffi, OpenSSL, libgcrypt, libgpg-error, zstd | various OSS (MIT/BSD/LGPL/Apache/OpenSSL) | UTM `patches/sources` |
| CocoaSpice | Apache-2.0 | https://github.com/utmapp/CocoaSpice (pinned d8d29fc) |

The GPL/LGPL components are shipped as separate dynamic frameworks with their
source available at the URLs above (exact versions in UTM's
`patches/sources` at tag v5.0.8). Anyone redistributing an iDeck IPA must
provide or point to that corresponding source.

## Downloaded at install time (never bundled)

| Component | License | From |
|---|---|---|
| Debian 13 packages (runtime image) | various, recorded in `packages.lock` | deb.debian.org |
| Linux kernel | GPL-2.0 | Debian |
| Mesa | MIT | Debian trixie-backports |
| Steam client (linuxarm64) | Steam Subscriber Agreement (proprietary) | client-update.steamstatic.com, downloaded by the user's own guest |
| FEX-Emu RootFS (Ubuntu 24.04 EroFS) | various | rootfs.fex-emu.gg |
| Proton, Steam Linux Runtime | Valve / various | installed by Steam |
