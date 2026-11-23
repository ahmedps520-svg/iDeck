#!/usr/bin/env python3
"""Compare fpcheck digests and benchmark results between environments.

    compare.py --native out/native --off out/vfp-off --on out/vfp-on \
        [--also NAME:DIR ...] [--md FILE]

Each directory holds fpcheck.json and bench.json (run_guest_tests.py for
the guests; the same binaries run directly on the runner for "native").

Exit status 1 if, with host VFP on (--on and every --also), any pattern's
register results differ from real hardware, any pattern raised SIGILL, or
the mixed sequences differ.  Differences of the unpatched path (QEMU's own softfloat against
hardware) are reported, not failed.  FPSR flag differences are reported
and fail only with --strict-flags.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load(d: Path, name: str) -> dict | None:
    try:
        return json.loads((d / name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def diff_patterns(a: dict, b: dict, index: int) -> list[str]:
    """Pattern names whose digest (0 = values, 1 = flags) differs."""
    pa, pb = a.get("patterns", {}), b.get("patterns", {})
    return sorted(n for n in pa.keys() & pb.keys() if pa[n][index] != pb[n][index])


def missing_patterns(a: dict, b: dict) -> list[str]:
    return sorted(set(a.get("patterns", {})) ^ set(b.get("patterns", {})))


def fpcheck_report(native: dict, guest: dict, label: str) -> tuple[list[str], dict]:
    lines = []
    values = diff_patterns(native, guest, 0)
    flags = diff_patterns(native, guest, 1)
    missing = missing_patterns(native, guest)
    mix_values = native.get("mix_values") != guest.get("mix_values")
    mix_flags = native.get("mix_flags") != guest.get("mix_flags")
    n = len(native.get("patterns", {}))
    lines.append(f"### {label} against hardware")
    lines.append("")
    lines.append(f"- patterns compared: {n - len(missing)} of {native.get('patterns_total')}")
    lines.append(f"- register results differ: {len(values)}" + (f" ({', '.join(values)})" if values else ""))
    lines.append(f"- FPSR flags differ: {len(flags)}" + (f" ({', '.join(flags)})" if flags else ""))
    lines.append(f"- mixed sequences: values {'DIFFER' if mix_values else 'equal'}, "
                 f"flags {'DIFFER' if mix_flags else 'equal'} ({guest.get('mix_runs')} runs)")
    if guest.get("sigill"):
        lines.append(f"- SIGILL in the guest: {', '.join(guest['sigill'])}")
    if missing:
        lines.append(f"- not run on both sides: {', '.join(missing)}")
    lines.append(f"- guest time: {guest.get('seconds')} s for {guest.get('runs')} runs, "
                 f"mixed {guest.get('mix_seconds')} s")
    lines.append("")
    result = {"values": values, "flags": flags, "missing": missing, "mix_values": mix_values,
              "mix_flags": mix_flags, "sigill": guest.get("sigill", [])}
    return lines, result


def bench_table(rows: dict[str, dict | None]) -> list[str]:
    names: list[str] = []
    for data in rows.values():
        for r in (data or {}).get("results", []):
            if r["name"] not in names:
                names.append(r["name"])

    def value(data: dict | None, name: str) -> float | None:
        for r in (data or {}).get("results", []):
            if r["name"] == name and r.get("ok"):
                return r["value"]
        return None

    labels = list(rows)
    # A ratio against vfp-off for every guest configuration after it.
    ratio_of = [label for label in labels if label not in ("native", "vfp-off")]
    lines = ["| benchmark | unit | " + " | ".join(labels) + " | "
             + " | ".join(f"{label} / off" for label in ratio_of) + " |",
             "|---|---|" + "---:|" * (len(labels) + len(ratio_of))]
    for name in names:
        unit = ""
        for data in rows.values():
            for r in (data or {}).get("results", []):
                if r["name"] == name:
                    unit = r.get("unit", "")
        cells = []
        for label in labels:
            v = value(rows[label], name)
            cells.append("n/a" if v is None else f"{v:,.2f}")
        off = value(rows.get("vfp-off"), name)
        ratios = []
        for label in ratio_of:
            v = value(rows[label], name)
            ratios.append("" if not off or v is None else f"{v / off:.2f}x")
        lines.append(f"| {name} | {unit} | " + " | ".join(cells) + " | " + " | ".join(ratios) + " |")
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--native", required=True, type=Path)
    ap.add_argument("--off", required=True, type=Path)
    ap.add_argument("--on", required=True, type=Path)
    ap.add_argument("--also", action="append", default=[], metavar="NAME:DIR",
                    help="a further guest configuration, checked like --on")
    ap.add_argument("--md", type=Path, help="also append the report to this file")
    ap.add_argument("--strict-flags", action="store_true")
    args = ap.parse_args()

    out: list[str] = ["## Host VFP: results compared with real hardware", ""]
    failed = False
    native = load(args.native, "fpcheck.json")
    if not native or not native.get("patterns"):
        print("no native fpcheck result", file=sys.stderr)
        return 2
    if native.get("sigill"):
        out.append(f"**SIGILL on hardware: {', '.join(native['sigill'])}** (not ARMv8.0 or a wrong encoding)")
        out.append("")
        failed = True

    also = []
    for spec in args.also:
        name, _, d = spec.partition(":")
        also.append((name, Path(d)))
    for label, d, gate in [("QEMU as shipped by UTM (helpers)", args.off, False),
                           ("QEMU with host VFP", args.on, True)] + \
                          [(f"QEMU, {name}", d, True) for name, d in also]:
        guest = load(d, "fpcheck.json")
        if not guest or not guest.get("patterns"):
            out.append(f"### {label}: no result")
            out.append("")
            failed = failed or gate
            continue
        lines, res = fpcheck_report(native, guest, label)
        out += lines
        if gate and (res["values"] or res["mix_values"] or res["sigill"] or res["missing"]):
            failed = True
        if gate and args.strict_flags and (res["flags"] or res["mix_flags"]):
            failed = True

    out.append("## Benchmarks (same binary; guest numbers are 4 vCPUs under TCG)")
    out.append("")
    rows = {
        "native": load(args.native, "bench.json"),
        "vfp-off": load(args.off, "bench.json"),
        "vfp-on": load(args.on, "bench.json"),
    }
    for name, d in also:
        rows[name] = load(d, "bench.json")
    out += bench_table(rows)
    out.append("")
    out.append("**Result: " + ("FAILED" if failed else "host VFP matches hardware") + "**")
    text = "\n".join(out) + "\n"
    print(text)
    if args.md:
        with open(args.md, "a", encoding="utf-8") as f:
            f.write(text)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
