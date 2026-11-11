#!/usr/bin/env python3
"""Build and test the iDeck native core without CMake.

Uses `zig c++` (pip package `ziglang`) when available so the same command
works on Windows, Linux and macOS, and can cross-compile the guest agent and
benchmarks for aarch64 Linux. Falls back to $CXX / c++.

  python tools/build_core.py test                 # build + run unit tests
  python tools/build_core.py agent --target aarch64-linux-musl
  python tools/build_core.py bench --target aarch64-linux-musl
  python tools/build_core.py all  --target aarch64-linux-musl
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "core"
OUT = ROOT / "build" / "core"


def compiler(lang: str) -> list[str]:
    env = os.environ.get("CXX" if lang == "c++" else "CC")
    if env:
        return env.split()
    try:
        import ziglang  # noqa: F401  (pip install ziglang)

        return [sys.executable, "-m", "ziglang", lang]
    except ImportError:
        pass
    if shutil.which("zig"):
        return ["zig", lang]
    return ["c++" if lang == "c++" else "cc"]


def run(cmd: list[str], **kw) -> None:
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)


def exe_name(name: str, target: str | None) -> str:
    windows = (target is None and os.name == "nt") or (target and "windows" in target)
    return name + (".exe" if windows else "")


def core_sources() -> list[Path]:
    return sorted((CORE / "src").glob("*.cpp"))


def cxx_flags(target: str | None, debug: bool) -> list[str]:
    flags = ["-std=c++17", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
             "-I", str(CORE / "include")]
    flags += ["-O0", "-g"] if debug else ["-O2"]
    if target:
        flags += ["-target", target]
        if "linux" in target:
            flags += ["-static"] + ([] if debug else ["-s"])
    return flags


def build_tests(target: str | None, debug: bool) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / exe_name("ideck_core_tests" + (f"-{target}" if target else ""), target)
    srcs = core_sources() + sorted((CORE / "tests").glob("*.cpp"))
    run(compiler("c++") + cxx_flags(target, debug) + [str(s) for s in srcs] + ["-o", str(out)])
    return out


def build_shared_lib(target: str | None, debug: bool) -> Path:
    """libideck_core shared library (C API), used by tools/ideck_host.py."""
    OUT.mkdir(parents=True, exist_ok=True)
    windows = (target is None and os.name == "nt") or (target and "windows" in target)
    name = "ideck_core.dll" if windows else ("libideck_core.dylib" if sys.platform == "darwin" and target is None
                                             else "libideck_core.so")
    out = OUT / name
    flags = cxx_flags(target, debug)
    flags = [f for f in flags if f not in ("-static", "-s")] + ["-shared", "-fPIC"]
    run(compiler("c++") + flags + [str(s) for s in core_sources()] + ["-o", str(out)])
    return out


def build_agent(target: str | None, debug: bool) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / exe_name("ideck-agent" + (f"-{target}" if target else ""), target)
    srcs = [CORE / "src" / n for n in ("json.cpp", "protocol.cpp", "sha256.cpp")]
    srcs += [p for p in sorted((ROOT / "guest" / "agent").glob("*.cpp")) if not p.name.endswith("_tests.cpp")]
    libs = [] if (target is None and os.name == "nt") else ["-lpthread"]
    run(compiler("c++") + cxx_flags(target, debug) + ["-I", str(ROOT / "guest" / "agent")] +
        [str(s) for s in srcs] + libs + ["-o", str(out)])
    return out


def build_agent_tests(target: str | None, debug: bool) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / exe_name("ideck_agent_tests" + (f"-{target}" if target else ""), target)
    agent_dir = ROOT / "guest" / "agent"
    srcs = [CORE / "src" / n for n in ("json.cpp", "protocol.cpp")]
    srcs += [agent_dir / n for n in ("sysinfo.cpp", "gamepad.cpp", "agent_tests.cpp")]
    srcs += [CORE / "tests" / "test_main.cpp"]
    run(compiler("c++") + cxx_flags(target, debug) + ["-I", str(agent_dir)] + [str(s) for s in srcs] +
        ["-o", str(out)])
    return out


def build_bench(target: str | None, debug: bool) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / exe_name("ideck-bench" + (f"-{target}" if target else ""), target)
    flags = ["-std=c11", "-O2", "-Wall", "-Wextra"]
    if target:
        flags += ["-target", target]
        if "linux" in target:
            flags += ["-static"]
    libs = [] if (target is None and os.name == "nt") else ["-lpthread", "-lm"]
    run(compiler("cc") + flags + [str(ROOT / "bench" / "ideck_bench.c"), "-o", str(out)] + libs)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["test", "agent", "bench", "lib", "all"])
    ap.add_argument("--target", default=None, help="zig target triple, e.g. aarch64-linux-musl")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--filter", default=None, help="run only tests whose name contains this")
    args = ap.parse_args()

    if args.what in ("test", "all"):
        exe = build_tests(args.target, args.debug)
        if args.target is None:
            cmd = [str(exe)] + ([args.filter] if args.filter else [])
            rc = subprocess.run(cmd).returncode
            if rc != 0:
                return rc
    if args.what in ("agent", "all"):
        tests = build_agent_tests(args.target, args.debug)
        if args.target is None:
            rc = subprocess.run([str(tests)]).returncode
            if rc != 0:
                return rc
        # The agent itself only runs on Linux; skip a native build elsewhere.
        if args.target is not None or sys.platform.startswith("linux"):
            build_agent(args.target, args.debug)
    if args.what in ("bench", "all"):
        build_bench(args.target, args.debug)
    if args.what in ("lib", "all"):
        build_shared_lib(args.target, args.debug)
    return 0


if __name__ == "__main__":
    sys.exit(main())
