#!/usr/bin/env python3
"""Compresses runtime artifacts and writes the runtime manifest.json.

  make_manifest.py --version 0.1.0 --base-url https://github.com/OWNER/REPO/releases/download/runtime-0.1.0 \
      --out dist/ --kernel out/Image --initrd out/initrd.img --system out/system.img \
      [--guest-info out/guest-info.json]

Each artifact is xz-compressed (single-threaded: one xz block stream that
Apple's Compression framework (COMPRESSION_LZMA) decodes as a stream) and
listed with the SHA-256 of both the download and the installed file. The
app refuses any artifact whose hashes do not match.
"""
import argparse
import hashlib
import json
import lzma
import os
import sys
from pathlib import Path

CHUNK = 1 << 22


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(CHUNK), b""):
            h.update(c)
    return h.hexdigest()


def compress(src: Path, dst: Path) -> None:
    filt = [{"id": lzma.FILTER_LZMA2, "preset": 6}]
    comp = lzma.LZMACompressor(format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64, filters=filt)
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        for c in iter(lambda: fi.read(CHUNK), b""):
            fo.write(comp.compress(c))
        fo.write(comp.flush())


def artifact(aid, role, src: Path, out: Path, base_url: str, sparse=False):
    dst = out / (src.name + ".xz")
    print(f"compressing {src} -> {dst}", flush=True)
    compress(src, dst)
    return {
        "id": aid,
        "role": role,
        "file": src.name,
        "url": f"{base_url.rstrip('/')}/{dst.name}",
        "sha256": sha256(dst),
        "size": dst.stat().st_size,
        "compression": "xz",
        "installed_size": src.stat().st_size,
        "installed_sha256": sha256(src),
        **({"sparse": True} if sparse else {}),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--channel", default="stable")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--kernel", type=Path, required=True)
    ap.add_argument("--initrd", type=Path)
    ap.add_argument("--system", type=Path, required=True)
    ap.add_argument("--guest-info", type=Path)
    ap.add_argument("--min-app-build", type=int, default=1)
    a = ap.parse_args()
    if not a.base_url.startswith("https://"):
        print("base URL must be https", file=sys.stderr)
        return 2
    a.out.mkdir(parents=True, exist_ok=True)
    arts = [artifact("kernel", "kernel", a.kernel, a.out, a.base_url)]
    if a.initrd:
        arts.append(artifact("initrd", "initrd", a.initrd, a.out, a.base_url))
    arts.append(artifact("system", "system-disk", a.system, a.out, a.base_url, sparse=True))
    guest = json.loads(a.guest_info.read_text()) if a.guest_info else {}
    manifest = {
        "schema": 1,
        "runtime_version": a.version,
        "channel": a.channel,
        "min_app_build": a.min_app_build,
        "kernel_cmdline": "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 loglevel=4 quiet "
                          "systemd.show_status=auto transparent_hugepage=never ideck.mode=gaming",
        "guest": guest,
        "defaults": {"cpu_model": "neoverse-n1", "cpus": 4},
        "artifacts": arts,
    }
    (a.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    total = sum(x["size"] for x in arts)
    print(f"manifest.json: runtime {a.version}, {len(arts)} artifacts, {total / 1e6:.1f} MB download")
    return 0


if __name__ == "__main__":
    sys.exit(main())
