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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True, help="path to libideck_core shared library")
    ap.add_argument("--runtime", required=True, type=Path, help="dir with Image, initrd.img, system.img")
    ap.add_argument("--report", required=True, type=Path)
    ap.add_argument("--qemu", default="qemu-system-aarch64")
    ap.add_argument("--memory", type=int, default=4096)
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--cpu-model", default="neoverse-n1")
    ap.add_argument("--data-size-gb", type=int, default=24)
    ap.add_argument("--timeout-boot", type=int, default=1800)
    ap.add_argument("--timeout-provision", type=int, default=5400)
    ap.add_argument("--steam-wait", type=int, default=3600)
    ap.add_argument("--steam-software-ui", action="store_true",
                    help="start Steam with -cef-disable-gpu -cef-disable-gpu-compositing (the app's Software-rendered Steam UI)")
    ap.add_argument("--steam-observe", type=int, default=0,
                    help="keep taking screenshots this many seconds after the first Steam window")
    ap.add_argument("--skip-bench", action="store_true")
    a = ap.parse_args()

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
        "tb_cache_mb": 512, "cpu_model": a.cpu_model, "gl": False, "vulkan": False,
        "qmp_socket": str(run / "q.sock"), "control_socket": str(run / "c.sock"),
        "input_socket": str(run / "i.sock"), "console_log": str(a.report / "console.log"), "audio": "none",
    }
    argv = core.call("qemu.args", cfg)["argv"]
    argv[0] = a.qemu
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
        log("status", agent.request("status"))

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

        if not a.skip_bench:
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
            except Exception as e:  # noqa: BLE001
                log("journal", f"{unit}: {e}", ok=False)

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
