#!/usr/bin/env python3
"""iDeck guest self-test: checks every layer the gaming stack depends on.

Prints a JSON report ({"ok": bool, "checks": [...]}) with --json. Each
check records what was observed, so failures are diagnosable from the app.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys

DECK = "deck"


def run(argv, timeout=60, as_deck=False):
    if as_deck:
        uid = 1000
        argv = ["runuser", "-u", DECK, "--", "env", "DISPLAY=:0", f"XDG_RUNTIME_DIR=/run/user/{uid}",
                f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"] + list(argv)
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr)
    except FileNotFoundError:
        return 127, f"{argv[0]}: not installed"
    except subprocess.TimeoutExpired:
        return 124, "timed out"


def check(checks, cid, ok, detail, required=True):
    checks.append({"id": cid, "ok": bool(ok), "required": required, "detail": str(detail)[:500]})


def cpu_features():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("Features"):
                    return line.split(":", 1)[1].split()
    except OSError:
        pass
    return []


def main() -> int:
    checks = []
    page = os.sysconf("SC_PAGE_SIZE")
    check(checks, "page-size", page == 4096, f"{page} bytes (Steam ARM64 client and FEX need 4 KiB)")
    feats = cpu_features()
    check(checks, "cpu-lse", "atomics" in feats, "LSE atomics " + ("present" if "atomics" in feats else "missing"))
    check(checks, "cpu-rcpc", "lrcpc" in feats, "LRCPC " + ("present" if "lrcpc" in feats else "missing"),
          required=False)

    rc, out = run(["findmnt", "-no", "SOURCE,FSTYPE,SIZE", "/home"])
    check(checks, "library-disk", rc == 0 and "ext4" in out, out.strip() or "not mounted")
    st = shutil.disk_usage("/home") if os.path.ismount("/home") else None
    if st:
        check(checks, "library-free", st.free > 2 << 30, f"{st.free >> 20} MiB free", required=False)

    try:
        socket.getaddrinfo("client-update.steamstatic.com", 443)
        check(checks, "network-dns", True, "client-update.steamstatic.com resolves")
    except OSError as e:
        check(checks, "network-dns", False, e)

    check(checks, "drm-render-node", os.path.exists("/dev/dri/renderD128"), "/dev/dri/renderD128")
    rc, out = run(["glxinfo", "-B"], as_deck=True)
    renderer = re.search(r"OpenGL renderer string: (.*)", out)
    gl_ver = re.search(r"OpenGL version string: (.*)", out)
    r = renderer.group(1) if renderer else out.strip()[:200]
    # virgl = host GPU through ANGLE/Metal; llvmpipe = software (not accelerated).
    check(checks, "opengl", rc == 0 and renderer is not None and "llvmpipe" not in r,
          f"{r}; {gl_ver.group(1) if gl_ver else ''}")
    rc, out = run(["vulkaninfo", "--summary"], timeout=120, as_deck=True)
    dev = re.search(r"deviceName\s*=\s*(.*)", out)
    api = re.search(r"apiVersion\s*=\s*(\S+)", out)
    d = dev.group(1).strip() if dev else "no device"
    # Optional: Steam and OpenGL games run without it, and the app turns
    # Venus off when iPadOS refuses its shared memory.
    check(checks, "vulkan", rc == 0 and dev is not None and "llvmpipe" not in d,
          f"{d}; api {api.group(1) if api else '?'}", required=False)

    rc, out = run(["pactl", "info"], as_deck=True)
    sink = re.search(r"Default Sink: (.*)", out)
    # "auto_null" is PipeWire's dummy sink: no audio device reached the guest.
    real_sink = sink is not None and sink.group(1).strip() not in ("", "auto_null")
    check(checks, "audio", rc == 0 and real_sink, sink.group(1) if sink else out.strip()[:200])

    check(checks, "uinput", os.path.exists("/dev/uinput"), "/dev/uinput (virtual controllers)")
    rc, out = run(["systemctl", "is-active", "ideck-agent.service"])
    check(checks, "agent", out.strip() == "active", out.strip())

    steam = "/home/deck/.local/share/Steam/steamrtarm64/steam"
    check(checks, "steam-client", os.access(steam, os.X_OK), steam, required=False)
    # Every library the client's main binaries need must resolve (runtime
    # 0.1.2: steamui.so could not load libgtk-x11-2.0.so.0).
    steam_dir = os.path.dirname(steam)
    if os.path.isdir(steam_dir):
        missing = set()
        for name in ("steam", "steamui.so", "steamclient.so", "vgui2_s.so", "steamwebhelper"):
            path = os.path.join(steam_dir, name)
            if not os.path.exists(path):
                continue
            rc, out = run(["env", f"LD_LIBRARY_PATH={steam_dir}", "ldd", path])
            for line in out.splitlines():
                if "not found" in line:
                    missing.add(f"{line.split('=>')[0].strip()} ({name})")
        check(checks, "steam-libs", not missing,
              "all client libraries resolve" if not missing else "missing: " + ", ".join(sorted(missing)),
              required=False)
    fex = "/usr/share/guestos/fex-mesa"
    check(checks, "fex-rootfs", os.path.isdir(os.path.join(fex, "usr")), fex, required=False)
    rc, out = run(["sysctl", "-n", "kernel.unprivileged_userns_clone"])
    if rc == 0:
        check(checks, "userns", out.strip() == "1", f"unprivileged_userns_clone={out.strip()}")
    rc, out = run(["unshare", "--user", "--map-root-user", "true"], as_deck=True)
    check(checks, "userns-works", rc == 0, "unshare --user (Steam runtime containers)" + (": " + out if rc else ""))

    ok = all(c["ok"] for c in checks if c["required"])
    report = {"ok": ok, "checks": checks}
    if "--json" in sys.argv:
        print(json.dumps(report, indent=2))
    else:
        for c in checks:
            mark = "ok  " if c["ok"] else ("FAIL" if c["required"] else "warn")
            print(f"{mark} {c['id']:<16} {c['detail']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
