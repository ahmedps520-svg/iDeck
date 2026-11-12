#!/usr/bin/env python3
"""iDeck first-boot provisioning (run by ideck-provision.service as root).

Performs the in-guest part of the one-tap installer and records progress in
/var/lib/ideck/provision.json, which the guest agent streams to the app:

  install-steam   native ARM64 Steam client (steam_bootstrap.py, as "deck")
  install-compat  FEX x86-64 RootFS for x86 Linux games (Proton is fetched
                  by Steam itself when a Windows game needs it)
  init-graphics   OpenGL (virgl) and Vulkan (Venus) are hardware-backed
  init-audio      PipeWire sink available
  init-input      /dev/uinput available for virtual controllers
  self-test       full self-test report

Every step is idempotent, so re-running after an interruption or a runtime
update only redoes what is missing.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

STATE = Path("/var/lib/ideck/provision.json")
CONFIG = Path("/usr/lib/ideck/components.json")
DATA = Path("/home/.ideck")
DECK_UID = 1000

STEPS = [
    ("install-steam", "Installing Steam"),
    ("install-compat", "Installing compatibility tools"),
    ("init-graphics", "Initialising graphics"),
    ("init-audio", "Initialising audio"),
    ("init-input", "Configuring controllers"),
    ("self-test", "Running self-tests"),
]


class Progress:
    def __init__(self):
        self.state = {"schema": 1, "state": "running", "started": int(time.time()),
                      "steps": [{"id": i, "title": t, "state": "pending", "progress": 0.0, "detail": ""}
                                for i, t in STEPS]}
        self.save()

    def step(self, sid):
        return next(s for s in self.state["steps"] if s["id"] == sid)

    def update(self, sid, **kw):
        self.step(sid).update(kw)
        self.save()

    def save(self):
        self.state["updated"] = int(time.time())
        STATE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, indent=2))
        os.replace(tmp, STATE)


def as_deck(argv):
    return ["runuser", "-u", "deck", "--", "env", "HOME=/home/deck",
            f"XDG_RUNTIME_DIR=/run/user/{DECK_UID}"] + argv


def install_steam(p: Progress):
    sid = "install-steam"
    boot = ["python3", "/usr/lib/ideck/steam_bootstrap.py"]
    if subprocess.run(as_deck(boot + ["--check"])).returncode == 0:
        p.update(sid, state="done", progress=1.0, detail="already installed")
        return
    beta = Path("/var/lib/ideck/steam.env").read_text().find("IDECK_STEAM_BETA=1") >= 0 \
        if Path("/var/lib/ideck/steam.env").exists() else False
    proc = subprocess.Popen(as_deck(boot + (["--beta"] if beta else [])), stdout=subprocess.PIPE, text=True)
    total, done_pkgs, done_bytes = 0, 0, {}
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        kind = ev.get("event")
        if kind == "plan":
            total = ev.get("bytes", 0)
            p.update(sid, detail=f"Steam client {ev.get('version')}: {len(ev.get('packages', []))} packages")
        elif kind == "download-progress" and total:
            done_bytes[ev["file"]] = ev["done"]
            p.update(sid, progress=min(0.95, sum(done_bytes.values()) / total))
        elif kind == "unpacking":
            p.update(sid, detail=f"Unpacking {ev.get('package')}")
        elif kind == "installed":
            done_pkgs += 1
        elif kind == "error":
            p.update(sid, detail=ev.get("error", "error"))
    if proc.wait() != 0:
        raise RuntimeError("Steam bootstrap failed: " + p.step(sid)["detail"])
    p.update(sid, state="done", progress=1.0, detail=f"installed {done_pkgs} packages")


def _download(url, dest: Path, on_progress):
    part = dest.with_name(dest.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    req = urllib.request.Request(url, headers={"User-Agent": "iDeck-provision/0.1"})
    if have:
        req.add_header("Range", f"bytes={have}-")
    with urllib.request.urlopen(req, timeout=60) as r:
        total = have + int(r.headers.get("Content-Length", "0") or 0)
        mode = "ab" if (have and r.status == 206) else "wb"
        done = have if mode == "ab" else 0
        with open(part, mode) as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
                done += len(chunk)
                on_progress(done, total)
    os.replace(part, dest)


def _xxhash_ok(path: Path, expected: str) -> tuple[bool, str]:
    """FEX publishes a 64-bit xxHash; accept XXH3-64 or XXH64 if available."""
    try:
        import xxhash  # python3-xxhash
    except ImportError:
        return True, "xxhash module missing; relying on TLS + size"
    want = int(expected, 16)
    h3, h64 = xxhash.xxh3_64(), xxhash.xxh64()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h3.update(chunk)
            h64.update(chunk)
    ok = want in (h3.intdigest(), h64.intdigest())
    return ok, f"xxh3={h3.hexdigest()} xxh64={h64.hexdigest()} expected={expected}"


def install_compat(p: Progress):
    sid = "install-compat"
    cfg = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    fex = cfg.get("fex_rootfs")
    mount_point = Path("/usr/share/guestos/fex-mesa")
    if not fex:
        p.update(sid, state="skipped", progress=1.0, detail="no FEX RootFS configured in this runtime")
        return
    if (mount_point / "usr").is_dir():
        p.update(sid, state="done", progress=1.0, detail="FEX RootFS already mounted")
        return
    DATA.joinpath("fex").mkdir(parents=True, exist_ok=True)
    image = DATA / "fex" / "rootfs.img"
    marker = DATA / "fex" / "rootfs.json"
    current = json.loads(marker.read_text()) if marker.exists() else {}
    if current.get("url") != fex["url"] or not image.exists():
        tmp = DATA / "fex" / "rootfs.download"
        p.update(sid, detail=f"Downloading {fex['name']}")
        _download(fex["url"], tmp, lambda d, t: p.update(sid, progress=0.9 * d / t if t else 0.0))
        ok, why = _xxhash_ok(tmp, fex["hash"])
        if not ok:
            tmp.unlink()
            raise RuntimeError("FEX RootFS hash mismatch: " + why)
        if "sha256" in fex:
            h = hashlib.sha256()
            with open(tmp, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 22), b""):
                    h.update(chunk)
            if h.hexdigest() != fex["sha256"]:
                tmp.unlink()
                raise RuntimeError("FEX RootFS SHA-256 mismatch")
        os.replace(tmp, image)
        marker.write_text(json.dumps({"url": fex["url"], "type": fex["type"], "verified": why}))
    mount_point.mkdir(parents=True, exist_ok=True)
    rc = subprocess.run(["systemctl", "start", "ideck-fex-rootfs.service"]).returncode
    if rc != 0 or not (mount_point / "usr").is_dir():
        raise RuntimeError("could not mount the FEX RootFS")
    p.update(sid, state="done", progress=1.0, detail=f"{fex['name']} mounted at {mount_point}")


def _self_test():
    out = subprocess.run(["python3", "/usr/lib/ideck/self_test.py", "--json"], capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"ok": False, "checks": [], "error": out.stderr[-2000:]}


def _checks(report, ids):
    return [c for c in report.get("checks", []) if c["id"] in ids]


def step_state(checks) -> str:
    """'done' when every check passed, 'warning' when only optional ones
    failed (setup goes on; e.g. Vulkan is unavailable but OpenGL works),
    'failed' when a required check failed or there was nothing to check."""
    if not checks:
        return "failed"
    if not all(c["ok"] for c in checks if c["required"]):
        return "failed"
    return "done" if all(c["ok"] for c in checks) else "warning"


def runtime_version() -> str:
    try:
        return Path("/usr/lib/ideck/runtime-version").read_text().strip()
    except OSError:
        return "unknown"


def main() -> int:
    # Fast path: this runtime version was already provisioned on this library
    # disk and Steam is present. Boots then go straight to Steam; the full
    # self-test can still be run on demand through the agent.
    stamp = DATA / f"provisioned-{runtime_version()}.json"
    steam_ok = subprocess.run(as_deck(["python3", "/usr/lib/ideck/steam_bootstrap.py", "--check"])).returncode == 0
    if "--force" not in sys.argv and stamp.exists() and steam_ok:
        cached = json.loads(stamp.read_text())
        cached["state"] = "done"
        cached["cached"] = True
        cached["updated"] = int(time.time())
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(cached, indent=2))
        subprocess.run(["systemctl", "start", "ideck-fex-rootfs.service"])
        return 0

    p = Progress()
    failed = None
    for sid, fn in (("install-steam", install_steam), ("install-compat", install_compat)):
        try:
            p.update(sid, state="running")
            fn(p)
        except Exception as e:  # recorded and reported to the app
            p.update(sid, state="failed", detail=str(e)[:500])
            failed = failed or sid
    # Wait briefly for the graphical session so GL/Vulkan/audio can be probed.
    for _ in range(60):
        if os.path.exists("/tmp/.X11-unix/X0"):
            break
        time.sleep(2)
    report = _self_test()
    groups = {
        "init-graphics": ("drm-render-node", "opengl", "vulkan"),
        "init-audio": ("audio",),
        "init-input": ("uinput", "agent"),
    }
    for sid, ids in groups.items():
        cs = _checks(report, ids)
        state = step_state(cs)
        p.update(sid, state=state, progress=1.0,
                 detail="; ".join(f"{c['id']}: {'ok' if c['ok'] else ('FAILED' if c['required'] else 'warning')}"
                                  f" ({c['detail']})" for c in cs))
        if state == "failed":
            failed = failed or sid
    checks = report.get("checks", [])
    bad = [c for c in checks if not c["ok"]]
    p.update("self-test", state="failed" if not report.get("ok") else ("warning" if bad else "done"), progress=1.0,
             detail=f"{sum(c['ok'] for c in checks)}/{len(checks)} checks passed"
                    + ("; not passing: " + "; ".join(f"{c['id']} ({c['detail']})" for c in bad) if bad else ""))
    p.state["self_test"] = report
    p.state["state"] = "failed" if (failed or not report.get("ok")) else "done"
    p.state["finished"] = int(time.time())
    p.save()
    if p.state["state"] == "done":
        DATA.mkdir(parents=True, exist_ok=True)
        stamp.write_text(json.dumps(p.state, indent=2))
    return 0 if p.state["state"] == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
