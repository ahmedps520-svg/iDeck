#!/usr/bin/env python3
"""Boot a tiny initramfs under a QEMU binary and collect the test output.

    run_guest_tests.py --qemu PATH --kernel Image --busybox /bin/busybox \
        --bin build/core/ideck-fpcheck-aarch64-linux-musl:ideck-fpcheck \
        --bin build/core/ideck-bench-aarch64-linux-musl:ideck-bench \
        --out out/engine/vfp-on --cpu max,pauth=off,sve=off,sme=off,x-host-vfp=on

The guest is the published iDeck kernel with engine/guest_init.sh as
/init: it runs the static test binaries on the serial console and powers
off.  Each "@@BEGIN name" ... "@@END name rc" section of the console log is
written to OUT/name.txt; sections that parse as JSON also to OUT/name.json.
"""
from __future__ import annotations

import argparse
import gzip
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def cpio_newc(entries: list[tuple[str, int, bytes]]) -> bytes:
    """A newc cpio archive of (name, mode, data); directories have data b''."""
    out = bytearray()

    def add(name: str, mode: int, data: bytes, ino: int) -> None:
        n = name.encode() + b"\0"
        hdr = "070701" + "".join(
            f"{v:08X}" for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0)
        )
        out.extend(hdr.encode())
        out.extend(n)
        out.extend(b"\0" * (-len(out) % 4))
        out.extend(data)
        out.extend(b"\0" * (-len(out) % 4))

    for i, (name, mode, data) in enumerate(entries, start=1):
        add(name, mode, data, i)
    add("TRAILER!!!", 0, b"", 0)
    out.extend(b"\0" * (-len(out) % 512))
    return bytes(out)


def build_initramfs(busybox: Path, bins: list[tuple[Path, str]], init: Path) -> bytes:
    d, f = 0o040755, 0o100755
    entries: list[tuple[str, int, bytes]] = [
        ("bin", d, b""), ("dev", d, b""), ("proc", d, b""), ("sys", d, b""), ("tmp", d, b""),
        ("bin/busybox", f, busybox.read_bytes()),
        ("init", f, init.read_bytes().replace(b"\r\n", b"\n")),
    ]
    for src, name in bins:
        entries.append((name, f, src.read_bytes()))
    return gzip.compress(cpio_newc(entries), compresslevel=6)


SECTION = re.compile(r"^@@BEGIN (\S+)\r?\n(.*?)^@@END \1 (-?\d+)\r?$", re.S | re.M)


def split_sections(log: str) -> dict[str, tuple[int, str]]:
    return {m.group(1): (int(m.group(3)), m.group(2).replace("\r\n", "\n")) for m in SECTION.finditer(log)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--kernel", required=True, type=Path)
    ap.add_argument("--busybox", required=True, type=Path)
    ap.add_argument("--bin", action="append", default=[], help="HOSTPATH:NAME, placed at /NAME")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--cpu", default="max,pauth=off,sve=off,sme=off")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--memory", type=int, default=2048)
    ap.add_argument("--tb-size", type=int, default=1024)
    ap.add_argument("--append", default="", help="extra kernel command line")
    ap.add_argument("--timeout", type=int, default=3600)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    bins = []
    for spec in args.bin:
        src, _, name = spec.rpartition(":")
        bins.append((Path(src), name))
    initrd = args.out / "test-initramfs.cpio.gz"
    initrd.write_bytes(build_initramfs(args.busybox, bins, HERE / "guest_init.sh"))
    console = args.out / "console.log"
    if console.exists():
        console.unlink()

    cmdline = ("console=ttyAMA0 loglevel=4 transparent_hugepage=never mitigations=off "
               "nowatchdog kpti=0 panic=-1 " + args.append).strip()
    cmd = [
        args.qemu, "-nodefaults", "-no-user-config", "-display", "none", "-no-reboot",
        "-machine", "virt,gic-version=3",
        "-accel", f"tcg,thread=multi,tb-size={args.tb_size}",
        "-cpu", args.cpu,
        "-smp", str(args.cpus), "-m", f"{args.memory}M",
        "-kernel", str(args.kernel), "-initrd", str(initrd), "-append", cmdline,
        "-serial", f"file:{console}",
    ]
    print("+", " ".join(cmd), flush=True)
    t0 = time.time()
    try:
        rc = subprocess.run(cmd, timeout=args.timeout).returncode
    except subprocess.TimeoutExpired:
        rc = -1
        print(f"QEMU did not exit within {args.timeout} s", flush=True)
    seconds = time.time() - t0

    log = console.read_text(errors="replace") if console.exists() else ""
    sections = split_sections(log)
    summary = {"qemu_rc": rc, "seconds": round(seconds, 1), "done": "@@DONE" in log,
               "cpu": args.cpu, "sections": {}}
    for name, (src_rc, text) in sections.items():
        (args.out / f"{name}.txt").write_text(text, encoding="utf-8")
        entry = {"rc": src_rc, "bytes": len(text)}
        start = text.find("{")
        if start >= 0:
            try:
                data = json.loads(text[start:])
                (args.out / f"{name}.json").write_text(json.dumps(data, indent=1), encoding="utf-8")
                entry["json"] = True
            except ValueError:
                pass
        summary["sections"][name] = entry
    (args.out / "summary.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(json.dumps(summary, indent=1))
    if not summary["done"]:
        print("---- console tail ----")
        print("\n".join(log.splitlines()[-60:]))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
