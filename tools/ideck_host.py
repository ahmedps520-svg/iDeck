#!/usr/bin/env python3
"""iDeck desktop test host: boots a runtime image under stock QEMU and
drives it exactly as the iPad app does (same core library for the QEMU
command line, same agent protocol, same controller packets).

Used by CI to produce real evidence for each runtime build:
  * boot time to the guest agent's "ready" event
  * guest provisioning (Steam ARM64 client download + install, FEX RootFS)
  * self-test report, CPU benchmark (TCG), virtual controller creation
  * QMP screenshots of the guest display (e.g. the Steam window)

  python3 tools/ideck_host.py --core build/libideck_core.so --runtime out/ \
      --report out/boot-test --timeout-boot 1800 --steam-wait 1800
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class Core:
    def __init__(self, path: str):
        self.lib = ctypes.CDLL(path)
        self.lib.ideck_call.restype = ctypes.c_void_p
        self.lib.ideck_call.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        self.lib.ideck_free.argtypes = [ctypes.c_void_p]
        self.lib.ideck_input_encode.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

    def call(self, method: str, args: dict):
        p = self.lib.ideck_call(method.encode(), json.dumps(args).encode())
        try:
            reply = json.loads(ctypes.string_at(p).decode())
        finally:
            self.lib.ideck_free(p)
        if not reply.get("ok"):
            raise RuntimeError(f"{method}: {reply.get('error')}")
        return reply["result"]


class PadState(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint8), ("pad", ctypes.c_uint8), ("kind", ctypes.c_uint8),
                ("seq", ctypes.c_uint16), ("buttons", ctypes.c_uint32),
                ("lx", ctypes.c_float), ("ly", ctypes.c_float), ("rx", ctypes.c_float), ("ry", ctypes.c_float),
                ("lt", ctypes.c_float), ("rt", ctypes.c_float)]


class LineChannel:
    def __init__(self, path: str, timeout: float = 120):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.buf = b""
        self.backlog: list[dict] = []

    def send(self, obj: dict, crlf=False):
        self.sock.sendall(json.dumps(obj).encode() + (b"\r\n" if crlf else b"\n"))

    def recv(self, timeout: float) -> dict | None:
        if self.backlog:
            return self.backlog.pop(0)
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                raise ConnectionError("channel closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        line = line.strip()
        return json.loads(line) if line else None


class Agent:
    def __init__(self, ch: LineChannel, log):
        self.ch, self.log, self.next_id = ch, log, 1
        self.events: list[dict] = []

    def wait_event(self, name: str, timeout: float):
        deadline = time.time() + timeout
        while time.time() < deadline:
            m = self.ch.recv(min(5, max(0.1, deadline - time.time())))
            if m and "event" in m:
                self.events.append(m)
                if m["event"] == "provision":
                    self.log("provision", m.get("data"))
                if m["event"] == name:
                    return m.get("data", {})
        return None

    def request(self, op: str, args: dict | None = None, timeout: float = 120):
        rid = self.next_id
        self.next_id += 1
        self.ch.send({"id": rid, "op": op, "args": args or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            m = self.ch.recv(min(5, max(0.1, deadline - time.time())))
            if not m:
                continue
            if "event" in m:
                self.events.append(m)
                continue
            if m.get("id") == rid:
                if not m.get("ok"):
                    raise RuntimeError(f"{op}: {m.get('error')}")
                return m.get("result")
        raise TimeoutError(op)


class QMP:
    def __init__(self, path: str):
        self.ch = LineChannel(path)
        greeting = self.ch.recv(30)
        assert greeting and "QMP" in greeting, greeting
        self.ch.send({"execute": "qmp_capabilities", "id": 0}, crlf=True)
        self._wait(0)

    def _wait(self, rid):
        while True:
            m = self.ch.recv(60)
            if m is None:
                raise TimeoutError("qmp")
            if m.get("id") == rid:
                if "error" in m:
                    raise RuntimeError(m["error"])
                return m.get("return")

    def run(self, cmd: str, args: dict | None = None, rid=[1]):
        rid[0] += 1
        msg = {"execute": cmd, "id": rid[0]}
        if args:
            msg["arguments"] = args
        self.ch.send(msg, crlf=True)
        return self._wait(rid[0])


def steam_updater_summary(journal: str) -> dict:
    """What the Steam client's own updater did after the bootstrap: package
    files it found missing, downloads it queued, the size of its update and
    whether it extracted or had nothing to do."""
    lines = journal.splitlines()
    total_kb = 0
    for ln in lines:
        if "Downloading update (" in ln and " of " in ln:
            try:
                total_kb = max(total_kb, int(ln.split(" of ")[1].split(" KB")[0].replace(",", "")))
            except (IndexError, ValueError):
                pass
    return {
        "missing_package_files": sum("missing or incorrect size" in ln for ln in lines),
        "pending_downloads": sum("Add pending download" in ln for ln in lines),
        "update_kb": total_kb,
        "extracted": any("Extracting package" in ln for ln in lines),
        "installing": any("Installing update" in ln for ln in lines),
        "uninstalled_manifest": any("uninstalled manifest found" in ln for ln in lines),
        "nothing_to_do": any("Nothing to do" in ln or "Download skipped" in ln for ln in lines),
        "manifest_lines": [ln.split("] ", 1)[-1] for ln in lines
                           if "Downloaded new manifest" in ln or "Download skipped:" in ln][-3:],
    }


JIT_KEYS = {
    "TB count": "tb_count",
    "TB flush count": "tb_flush",
    "TB invalidate count": "tb_invalidate",
    "TLB full flushes": "tlb_full_flushes",
    "TLB partial flushes": "tlb_partial_flushes",
}


def parse_jit_info(text: str) -> dict:
    """Numbers from QEMU's `info jit` (QMP x-query-jit): how full the TCG
    code buffer is, how many translation blocks exist, and how often the
    whole buffer was flushed (every flush stops all vCPUs and retranslates)."""
    out: dict = {}
    for ln in text.splitlines():
        ln = ln.strip()
        if ln.startswith("gen code size") and "/" in ln:
            used, total = ln[len("gen code size"):].strip().split("/", 1)
            try:
                out["gen_code_bytes"], out["code_buffer_bytes"] = int(used), int(total.split()[0])
            except ValueError:
                pass
            continue
        for key, name in JIT_KEYS.items():
            if ln.startswith(key + " "):
                val = ln[len(key):].strip().split()
                if val and val[0].isdigit():
                    out[name] = int(val[0])
    return out


def top_summary(top: dict) -> dict:
    """The agent's `top` reply cut down to what matters for Steam's UI."""
    procs = top.get("processes", []) or []
    helpers = [p for p in procs if str(p.get("comm", "")).startswith("steamwebhelper")]
    return {
        "cpu_percent": top.get("cpu_percent"),
        "online_cpus": top.get("online_cpus"),
        "by_command": (top.get("by_command") or [])[:6],
        "webhelper_cpus_allowed": sorted({str(p.get("cpus")) for p in helpers}),
        "webhelper_processes_listed": len(helpers),
        # All steamwebhelper processes (by_command covers every process).
        "webhelper": next(({"processes": g.get("processes"), "cpu": g.get("cpu"), "rss_mb": g.get("rss_mb")}
                           for g in top.get("by_command") or [] if g.get("comm") == "steamwebhelper"), None),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True, help="path to libideck_core shared library")
    ap.add_argument("--runtime", required=True, type=Path, help="dir with Image, initrd.img, system.img")
    ap.add_argument("--report", required=True, type=Path)
    ap.add_argument("--qemu", default="qemu-system-aarch64")
    ap.add_argument("--memory", type=int, default=4096)
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--cpu-model", default="neoverse-n1")
    ap.add_argument("--cpu-extra", default="",
                    help="appended to QEMU's -cpu value, e.g. x-host-vfp-debug=1 (engine diagnostics)")
    ap.add_argument("--tlb-keep-global", action="store_true",
                    help="keep kernel TLB entries across process switches (needs --qemu built with engine/qemu)")
    ap.add_argument("--host-vfp", action="store_true",
                    help="guest FP/SIMD instructions on the host CPU (needs --qemu built with engine/qemu)")
    ap.add_argument("--data-size-gb", type=int, default=24)
    ap.add_argument("--timeout-boot", type=int, default=1800)
    ap.add_argument("--timeout-provision", type=int, default=5400)
    ap.add_argument("--steam-wait", type=int, default=3600)
    ap.add_argument("--steam-software-ui", action="store_true",
                    help="start Steam with -cef-disable-gpu -cef-disable-gpu-compositing (the app's Software-rendered Steam UI)")
    ap.add_argument("--steam-observe", type=int, default=0,
                    help="keep taking screenshots this many seconds after the first Steam window")
    ap.add_argument("--skip-bench", action="store_true")
    ap.add_argument("--steam-apply-update", action="store_true",
                    help="restart Steam once, wait for its update check and report whether it installed again")
    ap.add_argument("--bench-only", action="store_true",
                    help="boot with ideck.noprovision (no Steam, no provisioning), run the benchmark, power off")
    ap.add_argument("--cmdline-remove", action="append", default=[],
                    help="drop this word from the kernel command line (repeatable)")
    ap.add_argument("--cmdline-add", action="append", default=[],
                    help="append this word to the kernel command line (repeatable)")
    ap.add_argument("--tb-cache-mb", type=int, default=512,
                    help="TCG translation cache (tb-size); the iPad uses 384 for a 4 GiB guest")
    ap.add_argument("--steam-pin-ab", action="store_true",
                    help="restart Steam with and without Steam's CPU pinning of steamwebhelper and time its window")
    ap.add_argument("--steam-zink-check", action="store_true",
                    help="restart Steam with its UI on the GPU through Zink and check that the window draws")
    a = ap.parse_args()
    if a.bench_only:
        a.cmdline_add.append("ideck.noprovision")

    a.report.mkdir(parents=True, exist_ok=True)
    u = os.uname()  # a struct sequence: no _asdict()
    host = {k: getattr(u, k) for k in ("sysname", "nodename", "release", "version", "machine")}
    report: dict = {"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "host": host,
                    "steps": []}
    t0 = time.time()

    def log(step, data=None, ok=True):
        entry = {"t": round(time.time() - t0, 1), "step": step, "ok": ok, "data": data}
        report["steps"].append(entry)
        print(json.dumps(entry)[:2000], flush=True)
        (a.report / "report.json").write_text(json.dumps(report, indent=2))

    core = Core(a.core)
    run = Path(tempfile.mkdtemp(prefix="ideck-"))
    data = run / "data.img"
    core.call("storage.create_sparse", {"path": str(data), "size": a.data_size_gb << 30})
    system = run / "system.img"
    shutil.copy2(a.runtime / "system.img", system)  # keep the artifact pristine
    cfg = {
        "profile": "desktop-test", "kernel": str(a.runtime / "Image"), "initrd": str(a.runtime / "initrd.img"),
        "system_disk": str(system), "data_disk": str(data), "guest_mb": a.memory, "cpus": a.cpus,
        "tb_cache_mb": a.tb_cache_mb, "cpu_model": a.cpu_model, "host_vfp": a.host_vfp,
        "tlb_keep_global": a.tlb_keep_global,
        "gl": False, "vulkan": False,
        "qmp_socket": str(run / "q.sock"), "control_socket": str(run / "c.sock"),
        "input_socket": str(run / "i.sock"), "console_log": str(a.report / "console.log"), "audio": "none",
    }
    argv = core.call("qemu.args", cfg)["argv"]
    argv[0] = a.qemu
    if a.cpu_extra:
        i = argv.index("-cpu") + 1
        argv[i] = argv[i] + "," + a.cpu_extra
    if a.cmdline_remove or a.cmdline_add:
        i = argv.index("-append") + 1
        words = [w for w in argv[i].split() if w not in a.cmdline_remove]
        argv[i] = " ".join(words + [w for w in a.cmdline_add if w not in words])
    report["kernel_cmdline"] = argv[argv.index("-append") + 1]
    (a.report / "qemu-argv.json").write_text(json.dumps(argv, indent=2))
    log("qemu-start", {"argv": " ".join(argv)})
    qemu = subprocess.Popen(argv, stdout=open(a.report / "qemu.log", "w"), stderr=subprocess.STDOUT)
    rc = 1
    try:
        qmp = QMP(str(run / "q.sock"))
        log("qmp-connected", qmp.run("query-status"))
        agent = Agent(LineChannel(str(run / "c.sock")), log)
        ready = agent.wait_event("ready", a.timeout_boot)
        if ready is None:
            log("boot", "agent not ready before timeout", ok=False)
            return 1
        report["boot_seconds"] = round(time.time() - t0, 1)
        log("agent-ready", ready)
        report["kpti"] = (ready or {}).get("kpti", "")
        log("status", agent.request("status"))

        def fpcheck():
            """Every FP instruction pattern in the guest against the hardware reference in the image."""
            try:
                r = agent.request("fpcheck.run", {"quick": False}, timeout=3600)
            except Exception as e:  # an image without the check, or a failed run
                log("fpcheck", str(e), ok=False)
                return
            (a.report / "fpcheck.json").write_text(json.dumps(r, indent=2))
            report["fpcheck"] = r
            log("fpcheck", r, ok=bool(r.get("match")) and bool(r.get("flags_match")))

        if a.bench_only:
            fpcheck()
            bench = agent.request("bench.run", {"quick": False}, timeout=3600)
            (a.report / "bench.json").write_text(json.dumps(bench, indent=2))
            report["bench"] = {r["name"]: r.get("value") for r in bench.get("results", []) if r.get("ok")}
            log("benchmark", report["bench"])
            agent.request("power.off")
            qemu.wait(timeout=180)
            log("shutdown", {"qemu_exit": qemu.returncode})
            return 0

        # Controller path: connect a virtual pad and confirm the kernel sees it.
        inp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        inp.connect(str(run / "i.sock"))
        buf = ctypes.create_string_buffer(32)
        for t in (2, 1):
            st = PadState(type=t, pad=0, kind=1, seq=1, buttons=1, lx=0.5)
            core.lib.ideck_input_encode(ctypes.byref(st), buf)
            inp.sendall(buf.raw)
        time.sleep(2)
        devs = agent.request("input.devices")["devices"]
        log("virtual-controller", devs, ok=any("X-Box 360" in d for d in devs))

        # Provisioning (Steam ARM64 client install etc.).
        deadline = time.time() + a.timeout_provision
        prov = {}
        while time.time() < deadline:
            prov = agent.request("provision.status") or {}
            if prov.get("state") in ("done", "failed"):
                break
            agent.wait_event("__none__", 30)
        log("provision", prov, ok=prov.get("state") == "done")
        if a.steam_software_ui:
            # Same path as the app: write the launch options, restart Steam.
            try:
                agent.request("steam.configure", {"cef_software": True})
                log("steam-software-ui", agent.request("steam.restart", timeout=120))
            except Exception as e:  # noqa: BLE001  (keep observing Steam either way)
                log("steam-software-ui", str(e), ok=False)
        log("steam-status", agent.request("steam.status"))

        # The refresh-rate setting: X accepts a 120 Hz mode on virtio-gpu.
        for hz in (120, 60):
            try:
                r = agent.request("display.set", {"width": 1280, "height": 720, "refresh": hz}, timeout=60)
                out = (r or {}).get("output", "") if isinstance(r, dict) else str(r)
                log(f"display-{hz}hz", out.strip()[-300:], ok=f"{hz}." in out or f"{hz - 1}." in out)
            except Exception as e:  # noqa: BLE001
                log(f"display-{hz}hz", str(e), ok=False)

        if not a.skip_bench:
            fpcheck()
            try:
                bench = agent.request("bench.run", {"quick": False}, timeout=3600)
                (a.report / "bench.json").write_text(json.dumps(bench, indent=2))
                log("benchmark", bench)
            except Exception as e:  # noqa: BLE001
                log("benchmark", str(e), ok=False)

        # Steam window: screenshot every 2 minutes. An empty session (only
        # the background colour) compresses to ~5 KB; once a frame is much
        # larger a window is on screen, so take one more and stop.
        deadline = time.time() + a.steam_wait
        shot = 0
        window_seen_at = None
        while time.time() < deadline:
            st = agent.request("steam.status")
            path = a.report / f"screen-{shot:02d}.png"
            size = 0
            try:
                qmp.run("screendump", {"filename": str(path), "format": "png"})
                time.sleep(1)
                size = path.stat().st_size if path.exists() else 0
            except Exception as e:  # noqa: BLE001
                log("screendump", str(e), ok=False)
            log("steam-wait", {"pids": st.get("pids"), "service": st.get("service"), "screenshot": path.name,
                               "png_bytes": size})
            shot += 1
            if size > 20000 and window_seen_at is None:
                window_seen_at = shot
                report["steam_window_seconds"] = round(time.time() - t0, 1)
                deadline = min(deadline, time.time() + max(a.steam_observe, 1))
            elif window_seen_at is not None and a.steam_observe <= 0:
                break
            time.sleep(120)
        report["steam_window_seen"] = window_seen_at is not None

        # Steam's own output (stdout/stderr go to the journal of ideck-steam).
        for unit in ("ideck-steam.service", "ideck-provision.service", "ideck-session.service"):
            try:
                out = agent.request("logs", {"unit": unit, "lines": 1500}, timeout=120)
                (a.report / f"journal-{unit}.txt").write_text(out.get("output", ""))
                if unit == "ideck-steam.service":
                    report["steam_updater"] = steam_updater_summary(out.get("output", ""))
                    log("steam-updater", report["steam_updater"])
            except Exception as e:  # noqa: BLE001
                log("journal", f"{unit}: {e}", ok=False)

        # The client's updater state as the bootstrap left it, and (if the
        # client queued an install) as the client itself leaves it after a
        # restart applies it: shows which files record the installed version.
        def package_snapshot(name: str) -> dict:
            try:
                snap = agent.request("steam.package", timeout=60)
                (a.report / f"steam-package-{name}.json").write_text(json.dumps(snap, indent=2))
                small = {e["name"]: e["size"] for e in snap.get("entries", []) if ".zip." not in e["name"]}
                log(f"steam-package-{name}", small)
                return snap
            except Exception as e:  # noqa: BLE001
                log(f"steam-package-{name}", str(e), ok=False)
                return {}

        package_snapshot("before")

        # Steam's UI while the iPad shows iDeck's screens: steam-ui-daemon
        # minimises its windows ("away"). Guest CPU over 60 s with the window
        # shown, hidden, and shown again, plus a screenshot of each.
        def cpu_average(seconds: int):
            agent.request("status")  # starts a new sampling interval
            vals = []
            for _ in range(max(1, seconds // 5)):
                agent.wait_event("__none__", 5)
                v = agent.request("status").get("cpu_percent")
                if isinstance(v, (int, float)):
                    vals.append(v)
            return round(sum(vals) / len(vals), 1) if vals else None

        def screenshot(name: str) -> int:
            p = a.report / f"{name}.png"
            try:
                qmp.run("screendump", {"filename": str(p), "format": "png"})
                time.sleep(1)
                return p.stat().st_size
            except Exception:  # noqa: BLE001
                return 0

        def jit(label: str) -> dict:
            try:
                text = (qmp.run("x-query-jit") or {}).get("human-readable-text", "")
                (a.report / f"jit-{label}.txt").write_text(text)
                stats = parse_jit_info(text)
            except Exception as e:  # noqa: BLE001
                stats = {"error": str(e)}
            report.setdefault("jit", {})[label] = stats
            log(f"jit-{label}", stats)
            # Disk flushes so far (each one is a host fsync of the image).
            try:
                disks = {d.get("device") or d.get("qdev"): {k: d["stats"].get(k) for k in
                         ("flush_operations", "flush_total_time_ns", "wr_operations", "wr_bytes")}
                         for d in qmp.run("query-blockstats") or [] if "stats" in d}
                report.setdefault("disks", {})[label] = disks
                log(f"disks-{label}", disks)
            except Exception as e:  # noqa: BLE001
                log(f"disks-{label}", str(e), ok=False)
            return stats

        def top(label: str) -> dict:
            try:
                t = agent.request("top", {"interval_ms": 5000, "limit": 40}, timeout=60)
                (a.report / f"top-{label}.json").write_text(json.dumps(t, indent=2))
                s = top_summary(t)
            except Exception as e:  # noqa: BLE001
                s = {"error": str(e)}
            report.setdefault("top", {})[label] = s
            log(f"top-{label}", s)
            return s

        jit("steam-window")
        if window_seen_at is not None:
            top("steam-visible")
            try:
                report["webhelpers"] = agent.request("steam.webhelpers", timeout=60).get("processes")
                log("steam-webhelpers", report["webhelpers"])
            except Exception as e:  # noqa: BLE001
                log("steam-webhelpers", str(e), ok=False)
            ui: dict = {}
            try:
                ui["visible_cpu"] = cpu_average(60)
                ui["away_reply"] = agent.request("steam.ui", {"state": "away"}, timeout=30)
                agent.wait_event("__none__", 10)
                ui["away_png_bytes"] = screenshot("screen-steam-away")
                ui["away_cpu"] = cpu_average(60)
                ui["away_daemon"] = agent.request("steam.ui", {}, timeout=30).get("daemon")
                agent.request("steam.ui", {"state": "visible"}, timeout=30)
                agent.wait_event("__none__", 15)
                ui["visible_again_png_bytes"] = screenshot("screen-steam-visible-again")
                ui["visible_again_cpu"] = cpu_average(60)
                ui["visible_again_daemon"] = agent.request("steam.ui", {}, timeout=30).get("daemon")
                log("steam-ui", ui, ok=bool(ui.get("away_daemon")))
            except Exception as e:  # noqa: BLE001
                log("steam-ui", f"{e} ({ui})", ok=False)
            report["steam_ui"] = ui
            jit("after-ui")

        # A/B of Steam launch options: restart Steam with each set and time
        # it until the sign-in window is drawn again (a blank screen is ~4 KB
        # as PNG, the sign-in window ~34 KB), then sample processes and CPU.
        # --steam-pin-ab: Steam's own CPU pinning of steamwebhelper (2-6)
        # kept versus iDeck's override.
        def restart_timing(label: str, options: dict) -> dict:
            res: dict = dict(options)
            try:
                agent.request("steam.configure", {"lightweight": True, "cef_software": a.steam_software_ui,
                                                  **options})
                t_start = time.time()
                agent.request("steam.restart", timeout=120)
                # Wait for the old window to go, then for the new one.
                blank_at = None
                while time.time() - t_start < 120:
                    if screenshot(f"screen-ab-{label}") < 10000:
                        blank_at = time.time()
                        break
                    agent.wait_event("__none__", 3)
                res["stopped_s"] = round(blank_at - t_start, 1) if blank_at else None
                window_at = None
                while blank_at and time.time() - t_start < 900:
                    if screenshot(f"screen-ab-{label}") > 25000:
                        window_at = time.time()
                        # The next screenshot replaces this one: keep the first drawn frame.
                        shutil.copyfile(a.report / f"screen-ab-{label}.png",
                                        a.report / f"screen-ab-{label}-first.png")
                        break
                    agent.wait_event("__none__", 5)
                res["window_s"] = round(window_at - t_start, 1) if window_at else None
                if window_at:
                    agent.wait_event("__none__", 20)
                    res["png_bytes"] = screenshot(f"screen-ab-{label}")  # kept for a look
                    # The window must still be there: a web helper that
                    # crashes after its first frame leaves a blank screen.
                    res["still_drawn"] = res["png_bytes"] > 25000
                    if not res["still_drawn"]:
                        t_blank = time.time()
                        while time.time() - t_blank < 120:
                            agent.wait_event("__none__", 5)
                            if screenshot(f"screen-ab-{label}-later") > 25000:
                                res["redrawn_after_s"] = round(time.time() - t_blank, 1)
                                break
                    res["top"] = top(f"ab-{label}")
                    res["cpu_60s"] = cpu_average(60)
            except Exception as e:  # noqa: BLE001
                res["error"] = str(e)
            try:
                tail = agent.request("logs", {"unit": "ideck-steam.service", "lines": 400}, timeout=120)
                (a.report / f"journal-steam-{label}.txt").write_text(tail.get("output", ""))
            except Exception:  # noqa: BLE001
                pass
            log(f"steam-ab-{label}", res, ok=res.get("window_s") is not None)
            return res

        if a.steam_pin_ab and window_seen_at is not None:
            report["pin_ab"] = {
                "pinned": restart_timing("pinned", {"pin_webhelper": True}),
                "unpinned": restart_timing("unpinned", {"pin_webhelper": False}),
            }
            jit("after-pin-ab")
        if a.steam_zink_check and window_seen_at is not None:
            # GPU-drawn Steam UI through Zink. CI's Vulkan is lavapipe (CPU),
            # so this checks that the window draws, not how fast.
            # CI has no GPU and Zink ignores CPU Vulkan devices unless asked:
            # "zink-cpu" puts it on lavapipe, which checks Chromium on Zink.
            report["zink_check"] = restart_timing("zink", {"cef_software": False, "webhelper_gl": "zink-cpu"})
            try:
                report["zink_check"]["webhelpers"] = agent.request("steam.webhelpers", timeout=60).get("processes")
                log("steam-webhelpers-zink", report["zink_check"]["webhelpers"])
            except Exception as e:  # noqa: BLE001
                log("steam-webhelpers-zink", str(e), ok=False)
            restart_timing("back-to-default", {"webhelper_gl": ""})
            jit("after-zink")

        # A Steam restart (the next iDeck launch) must not install the
        # client again: with the bootstrap's package/*.manifest the updater
        # should report the installed version and skip.
        if a.steam_apply_update:
            def steam_journal() -> str:
                return agent.request("logs", {"unit": "ideck-steam.service", "lines": 3000}, timeout=120).get("output", "")

            before = steam_journal().splitlines()
            agent.request("steam.restart", timeout=60)
            done_at, new = None, []
            end = time.time() + 25 * 60
            while time.time() < end:
                agent.wait_event("__none__", 60)
                lines = steam_journal().splitlines()
                new = lines[len(before):] if len(lines) < 3000 else lines
                text = "\n".join(new)
                if "Update complete" in text or "Download skipped" in text or "Downloaded new manifest" in text:
                    done_at = round(time.time() - t0, 1)
                    break
            agent.wait_event("__none__", 90)  # let the restarted client write its state
            lines = steam_journal().splitlines()
            new = lines[len(before):] if len(lines) < 3000 else lines
            (a.report / "journal-ideck-steam.service-after-restart.txt").write_text("\n".join(new))
            after = steam_updater_summary("\n".join(new))
            report["steam_after_restart"] = {"checked_at": done_at, **after}
            log("steam-restart-check", report["steam_after_restart"],
                ok=done_at is not None and not after["installing"] and not after["pending_downloads"])
            package_snapshot("after-restart")

        try:
            log("selftest", agent.request("selftest.run", timeout=900))
        except Exception as e:  # noqa: BLE001
            log("selftest", str(e), ok=False)
        log("library", agent.request("steam.library", timeout=120))
        agent.request("power.off")
        qemu.wait(timeout=180)
        log("shutdown", {"qemu_exit": qemu.returncode})
        rc = 0
    except Exception as e:  # noqa: BLE001
        log("error", repr(e), ok=False)
    finally:
        if qemu.poll() is None:
            qemu.kill()
        report["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        (a.report / "report.json").write_text(json.dumps(report, indent=2))
        shutil.rmtree(run, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
