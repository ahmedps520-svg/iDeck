#!/usr/bin/env python3
"""iDeck Steam bootstrapper for the native ARM64 (linuxarm64) Steam client.

Valve publishes the ARM64 Linux client on its update CDN but not as a .deb
or through repo.steampowered.com. This tool installs it the same way the
client updates itself:

 1. fetch the client manifest (KeyValues text) for platform linuxarm64
 2. pick the packages needed to start the client
 3. download each over HTTPS with resume, verify the SHA-256 the manifest
    lists ("sha2"), and extract it into the Steam root
 4. restore exec bits (the zips store none), create the ~/.steam links the
    client expects, and record what was installed

The client then updates and verifies the remaining packages itself.

Only the Python standard library is used. Progress is printed as one JSON
object per line so the guest agent can forward it to the iPad app.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

CDN = "https://client-update.steamstatic.com"
PLATFORM = "linuxarm64"
STATE_VERSION = 1

# Minimum set to start the ARM64 client: the shared bootstrap (steam.sh)
# and the native client binaries (steamrtarm64/). Confirmed by inspecting
# the published packages: bins_linuxarm64_linuxarm64 contains
# steamrtarm64/steam (ELF aarch64).
MINIMAL_PACKAGES = ("steam_linuxarm64", "bins_linuxarm64_linuxarm64")
# The full set is the default. With only the minimal set the client starts,
# reports "installed version == manifest version, Nothing to do" and never
# fetches the rest (CEF/libcef.so, SDL3, codecs), so its UI cannot load.
# Seen in the runtime 0.1.2 boot test. Android (Lepton) is skipped.
SKIP_IN_FULL = ("bins_androidarm64_linuxarm64",)
# ELF e_machine of the native client. The linuxarm64 manifest also ships
# x86-64 files in steamrt64/ and x86 files in steamrt32/ (the client side of
# steamclient.so for x86 games run through FEX); steamrt64/steam is x86-64.
EM_AARCH64 = 0xB7


class BootstrapError(RuntimeError):
    pass


# ---- KeyValues (VDF) ------------------------------------------------------

def _tokens(text: str):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif c in "{}":
            yield c
            i += 1
        elif c == '"':
            i += 1
            out = []
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    esc = text[i + 1]
                    out.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"'}.get(esc, esc))
                    i += 2
                else:
                    out.append(text[i])
                    i += 1
            if i >= n:
                raise BootstrapError("unterminated string in manifest")
            i += 1
            yield ("str", "".join(out))
        elif c == "[":
            # Conditional such as [$LINUX]; applies to the previous pair.
            j = text.find("]", i)
            if j < 0:
                raise BootstrapError("unterminated conditional in manifest")
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in " \t\r\n{}\"":
                j += 1
            yield ("str", text[i:j])
            i = j


def parse_vdf(text: str) -> dict:
    """Parses Valve KeyValues text into nested dicts (later keys win)."""
    stack: list[dict] = [{}]
    key = None
    for tok in _tokens(text):
        if tok == "{":
            if key is None:
                raise BootstrapError("'{' without a key in manifest")
            child: dict = {}
            stack[-1][key] = child
            stack.append(child)
            key = None
        elif tok == "}":
            if len(stack) == 1:
                raise BootstrapError("unbalanced '}' in manifest")
            stack.pop()
            key = None
        else:
            value = tok[1]
            if key is None:
                key = value
            else:
                stack[-1][key] = value
                key = None
    if len(stack) != 1:
        raise BootstrapError("unbalanced '{' in manifest")
    return stack[0]


# ---- package selection ----------------------------------------------------

def client_packages(manifest: dict, platform: str = PLATFORM) -> tuple[str, dict]:
    root = manifest.get(platform)
    if not isinstance(root, dict):
        raise BootstrapError(f"manifest has no '{platform}' section")
    version = root.get("version", "")
    pkgs = {k: v for k, v in root.items() if isinstance(v, dict) and "file" in v}
    for name, p in pkgs.items():
        if not p.get("sha2") or len(p["sha2"]) != 64:
            raise BootstrapError(f"package {name} has no SHA-256")
        try:
            int(p.get("size", ""))
        except ValueError:
            raise BootstrapError(f"package {name} has no size") from None
    return version, pkgs


def select_packages(pkgs: dict, full: bool) -> list[str]:
    if full:
        names = [n for n in pkgs if n not in SKIP_IN_FULL]
    else:
        names = [n for n in MINIMAL_PACKAGES if n in pkgs]
        missing = [n for n in MINIMAL_PACKAGES if n not in pkgs]
        if missing:
            raise BootstrapError("manifest lacks required packages: " + ", ".join(missing))
    # The bootstrapper package must be extracted first, client binaries last
    # so a partially extracted tree never looks complete.
    names.sort(key=lambda n: (0 if pkgs[n].get("IsBootstrapperPackage") == "1" else 1,
                              1 if n == "bins_linuxarm64_linuxarm64" else 0, n))
    return names


# ---- I/O ------------------------------------------------------------------

def emit(event: str, **data) -> None:
    print(json.dumps({"event": event, **data}), flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path, size: int, sha256: str, attempts: int = 5, opener=None) -> None:
    """Downloads with HTTP range resume; verifies size and SHA-256."""
    opener = opener or urllib.request.urlopen
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size == size and sha256_file(dest) == sha256:
        emit("download-cached", file=dest.name)
        return
    part = dest.with_name(dest.name + ".part")
    last_err = None
    for attempt in range(1, attempts + 1):
        have = part.stat().st_size if part.exists() else 0
        if have > size:
            part.unlink()
            have = 0
        req = urllib.request.Request(url, headers={"User-Agent": "iDeck-bootstrap/0.1"})
        if have:
            req.add_header("Range", f"bytes={have}-")
        try:
            with opener(req, timeout=60) as resp:
                status = getattr(resp, "status", 200)
                mode = "ab" if (have and status == 206) else "wb"
                if mode == "wb":
                    have = 0
                done = have
                last_report = 0.0
                with open(part, mode) as out:
                    while True:
                        chunk = resp.read(1 << 16)
                        if not chunk:
                            break
                        out.write(chunk)
                        done += len(chunk)
                        now = time.monotonic()
                        if now - last_report > 0.5:
                            emit("download-progress", file=dest.name, done=done, total=size)
                            last_report = now
            if part.stat().st_size != size:
                raise BootstrapError(f"{dest.name}: got {part.stat().st_size} bytes, expected {size}")
            got = sha256_file(part)
            if got != sha256:
                part.unlink()
                raise BootstrapError(f"{dest.name}: SHA-256 mismatch ({got})")
            os.replace(part, dest)
            emit("download-done", file=dest.name, size=size)
            return
        except (urllib.error.URLError, OSError, BootstrapError) as e:
            last_err = e
            emit("download-retry", file=dest.name, attempt=attempt, error=str(e))
            time.sleep(min(30, 2 ** attempt))
    raise BootstrapError(f"download failed: {dest.name}: {last_err}")


def _is_executable_content(head: bytes, name: str) -> bool:
    return head.startswith(b"\x7fELF") or head.startswith(b"#!") or name.endswith(".sh")


def extract(zip_path: Path, root: Path) -> int:
    """Extracts safely (no absolute paths, '..' or writing through a
    symlinked directory); restores exec bits."""
    count = 0
    root = root.resolve()
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            target = (root / info.filename).resolve()
            if root != target and root not in target.parents:
                raise BootstrapError(f"unsafe path in {zip_path.name}: {info.filename}")
            # A symlink on the way would redirect the files somewhere else in
            # the tree (old layouts linked steamrt64 -> steamrtarm64, which
            # put x86-64 files over the ARM64 client).
            here = root
            for part in Path(info.filename).parts[:-1]:
                here = here / part
                if here.is_symlink():
                    raise BootstrapError(f"{zip_path.name}: {info.filename} would be written through the symlink {here}")
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_name(target.name + ".ideck-tmp")
            with z.open(info) as src, open(tmp, "wb") as dst:
                head = src.read(4)
                dst.write(head)
                while True:
                    b = src.read(1 << 20)
                    if not b:
                        break
                    dst.write(b)
            mode = 0o755 if _is_executable_content(head, info.filename) else 0o644
            os.chmod(tmp, mode)
            os.replace(tmp, target)
            count += 1
    return count


def _symlink(target: str | Path, link: Path) -> None:
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.exists():
        if link.is_symlink() and os.readlink(link) == str(target):
            return
        if link.is_dir() and not link.is_symlink():
            raise BootstrapError(f"{link} exists and is a directory")
        link.unlink()
    os.symlink(str(target), link)


def drop_legacy_layout(steam_root: Path) -> bool:
    """Runtimes up to 0.1.3 linked steamrt64 -> steamrtarm64. Extracting the
    full package set through that link mixes x86-64 files into the ARM64
    client, so the link goes and steamrtarm64 is reinstalled from scratch.
    Returns True when something was removed."""
    link = steam_root / "steamrt64"
    if not link.is_symlink():
        return False
    link.unlink()
    arm = steam_root / "steamrtarm64"
    if arm.is_dir() and not arm.is_symlink():
        shutil.rmtree(arm)
    emit("legacy-layout-removed", path=str(link))
    return True


def configure(steam_root: Path, home: Path, beta: bool) -> None:
    """Creates the layout the ARM64 client expects (see STEAM.md)."""
    (steam_root / "package").mkdir(parents=True, exist_ok=True)
    beta_file = steam_root / "package" / "beta"
    if beta:
        beta_file.write_text("publicbeta\n")
    elif beta_file.exists():
        beta_file.unlink()
    # ideck-steam-launch starts steamrtarm64/steam directly. steam.sh would
    # start steamrt64/steam (x86-64) when this flag exists, so it must not.
    flag = steam_root / ".steam-enable-steamrt64-client"
    if flag.exists():
        flag.unlink()
    drop_legacy_layout(steam_root)
    dot = home / ".steam"
    _symlink(steam_root, dot / "steam")
    _symlink(steam_root, dot / "root")
    _symlink(steam_root / "linuxarm64", dot / "sdkarm64")


def elf_machine(path: Path) -> int | None:
    try:
        with open(path, "rb") as f:
            head = f.read(20)
    except OSError:
        return None
    if len(head) < 20 or head[:4] != b"\x7fELF":
        return None
    return int.from_bytes(head[18:20], "little" if head[5] == 1 else "big")


def is_installed(steam_root: Path, state_path: Path | None = None) -> bool:
    """Native client binary present and, if a state file is given, a
    completed *full* install recorded there (a minimal install is not
    usable)."""
    exe = steam_root / "steamrtarm64" / "steam"
    if not (exe.is_file() and os.access(exe, os.X_OK)) or elf_machine(exe) != EM_AARCH64:
        return False
    if (steam_root / "steamrt64").is_symlink():
        return False
    if state_path is None:
        return True
    try:
        st = json.loads(state_path.read_text())
    except (OSError, ValueError):
        return False
    return st.get("status") == "installed" and st.get("mode") == "full"


def write_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(tmp, path)


def fetch_manifest(url: str, opener=None) -> str:
    opener = opener or urllib.request.urlopen
    req = urllib.request.Request(url, headers={"User-Agent": "iDeck-bootstrap/0.1"})
    with opener(req, timeout=60) as resp:
        return resp.read().decode("utf-8")


def bootstrap(steam_root: Path, home: Path, cache: Path, beta: bool, full: bool,
              manifest_url: str | None = None, opener=None, state_path: Path | None = None) -> dict:
    channel = "publicbeta" if beta else "stable"
    url = manifest_url or (f"{CDN}/steam_client_publicbeta_{PLATFORM}" if beta else f"{CDN}/steam_client_{PLATFORM}")
    emit("manifest", url=url, channel=channel)
    text = fetch_manifest(url, opener)
    version, pkgs = client_packages(parse_vdf(text))
    names = select_packages(pkgs, full)
    total = sum(int(pkgs[n]["size"]) for n in names)
    emit("plan", version=version, packages=names, bytes=total)
    previous = {}
    if state_path and state_path.exists():
        try:
            previous = json.loads(state_path.read_text())
        except ValueError:
            previous = {}
    steam_root.mkdir(parents=True, exist_ok=True)
    if drop_legacy_layout(steam_root):
        previous = {}  # the tree changed under the recorded packages
    state = {"schema": STATE_VERSION, "platform": PLATFORM, "channel": channel, "version": version,
             "mode": "full" if full else "minimal",
             "packages": {}, "status": "installing", "updated": int(time.time())}
    if state_path:
        write_state(state_path, state)
    # A retry after a failure resumes: the leading packages the last run of
    # the same client version already extracted are kept. Only a prefix in
    # install order, so files shared between packages end up the same.
    done_before = previous.get("packages", {}) if previous.get("version") == version else {}
    resuming = True
    for n in names:
        p = pkgs[n]
        prev = done_before.get(n, {})
        if resuming and prev.get("file") == p["file"] and prev.get("sha256") == p["sha2"]:
            state["packages"][n] = prev
            emit("already-installed", package=n)
            continue
        resuming = False
        z = cache / p["file"]
        download(f"{CDN}/{p['file']}", z, int(p["size"]), p["sha2"], opener=opener)
        files = extract(z, steam_root)
        state["packages"][n] = {"file": p["file"], "sha256": p["sha2"], "files": files}
        emit("installed", package=n, files=files)
        if state_path:
            write_state(state_path, state)
    configure(steam_root, home, beta)
    if not is_installed(steam_root):  # binary check; state is written below
        raise BootstrapError("ARM64 client binary steamrtarm64/steam missing or not aarch64 after install")
    state["status"] = "installed"
    state["updated"] = int(time.time())
    if state_path:
        write_state(state_path, state)
    # Cached zips are no longer needed once extracted.
    for n in names:
        try:
            (cache / pkgs[n]["file"]).unlink()
        except FileNotFoundError:
            pass
    emit("done", version=version)
    return state


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    home_default = Path(os.environ.get("HOME", "/home/deck"))
    ap.add_argument("--home", type=Path, default=home_default)
    ap.add_argument("--root", type=Path, default=None, help="Steam root (default ~/.local/share/Steam)")
    ap.add_argument("--cache", type=Path, default=None)
    ap.add_argument("--beta", action="store_true", help="use the publicbeta client")
    ap.add_argument("--minimal", action="store_true",
                    help="install only the bootstrapper and core binaries (testing; the client will not start its UI)")
    ap.add_argument("--check", action="store_true", help="exit 0 if a full install is present, 1 if not")
    ap.add_argument("--manifest-url", default=None)
    args = ap.parse_args(argv)
    root = args.root or args.home / ".local/share/Steam"
    cache = args.cache or args.home / ".cache/ideck/steam-bootstrap"
    state_path = args.home / ".local/share/ideck/steam-bootstrap.json"
    if args.check:
        return 0 if is_installed(root, state_path) else 1
    try:
        bootstrap(root, args.home, cache, args.beta, not args.minimal, args.manifest_url, state_path=state_path)
    except (BootstrapError, urllib.error.URLError, OSError) as e:
        emit("error", error=str(e))
        try:
            st = json.loads(state_path.read_text()) if state_path.exists() else {}
        except ValueError:
            st = {}
        st.update({"status": "failed", "error": str(e), "updated": int(time.time())})
        write_state(state_path, st)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
