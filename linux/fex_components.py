#!/usr/bin/env python3
"""Pins the FEX x86-64 RootFS used for x86 Linux games.

Reads FEX's official RootFS index (https://rootfs.fex-emu.gg/RootFS_links.json)
at image build time and records the chosen image's URL and published hash
in components.json, so every runtime version downloads exactly one known
image (verified against that hash in the guest).

  fex_components.py OUT.json [--distro "Ubuntu 24.04 (EroFS)"]
"""
import argparse
import json
import sys
import urllib.request

INDEX = "https://rootfs.fex-emu.gg/RootFS_links.json"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--distro", default="Ubuntu 24.04 (EroFS)")
    ap.add_argument("--index", default=INDEX)
    a = ap.parse_args()
    req = urllib.request.Request(a.index, headers={"User-Agent": "iDeck-image-build"})
    with urllib.request.urlopen(req, timeout=60) as r:
        idx = json.load(r)
    entries = idx.get("v1", {})
    e = entries.get(a.distro)
    if not e:
        print(f"{a.distro!r} not in FEX RootFS index; available: {', '.join(entries)}", file=sys.stderr)
        return 1
    if not e.get("URL", "").startswith("https://") or not e.get("Hash"):
        print("index entry lacks an https URL or hash", file=sys.stderr)
        return 1
    comp = {"fex_rootfs": {"name": a.distro, "url": e["URL"], "hash": e["Hash"], "type": e.get("Type", "")}}
    with open(a.out, "w") as f:
        json.dump(comp, f, indent=2)
    print(f"FEX RootFS pinned: {e['URL']} (hash {e['Hash']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
