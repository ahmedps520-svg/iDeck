#!/usr/bin/env python3
"""Records what this machine's CPU computes for every ideck-fpcheck pattern.

    fpcheck_reference.py <ideck-fpcheck binary> <output json>

The image build runs this on the arm64 build host, real hardware, and puts
the result in the image. Inside the guest, the agent's fpcheck.run runs the
same binary and compares: equal digests mean the emulator computed every
instruction pattern (bench/fpcheck.c) exactly as the hardware did.
"""
from __future__ import annotations

import json
import subprocess
import sys


def cpu_name() -> str:
    try:
        out = subprocess.run(["lscpu"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    for line in out.splitlines():
        if line.startswith("Model name:"):
            return line.split(":", 1)[1].strip()
    return "unknown"


def run(binary: str, *args: str) -> dict:
    proc = subprocess.run([binary, *args], capture_output=True, text=True, timeout=1800)
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        raise SystemExit(f"{binary} {' '.join(args)}: no JSON (exit {proc.returncode}): {proc.stdout[:300]}")
    if data.get("fpcheck") != 1 or not data.get("patterns"):
        raise SystemExit(f"{binary}: did not run here: {proc.stdout[:300]}")
    if data.get("sigill") or data.get("mix_sigill"):
        raise SystemExit(f"{binary}: SIGILL on this CPU: {data.get('sigill')} / mixed {data.get('mix_sigill')}")
    # Only what the comparison reads.
    return {k: data[k] for k in ("patterns", "mix_values", "mix_flags", "values", "flags", "runs", "mix_runs")}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    binary, out = sys.argv[1], sys.argv[2]
    ref = {"cpu": cpu_name(), "full": run(binary), "quick": run(binary, "--quick")}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(ref, f, separators=(",", ":"))
    print(f"fpcheck reference from {ref['cpu']}: {len(ref['full']['patterns'])} patterns, "
          f"values {ref['full']['values']}, mixed {ref['full']['mix_values']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
