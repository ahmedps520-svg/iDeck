#!/usr/bin/env python3
"""Lists the Steam library as JSON for the iDeck app (run as "deck").

Reads only files the Steam client writes locally: libraryfolders.vdf, the
appmanifest_*.acf of every library folder (installed and downloading games)
and each user's localconfig.vdf (last-played times). Nothing is fetched
from the network and no Steam credentials are touched.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from steam_bootstrap import parse_vdf  # noqa: E402  (same KeyValues parser)

STEAM = Path.home() / ".local/share/Steam"

# StateFlags bits from appmanifest files.
FULLY_INSTALLED = 4
UPDATE_REQUIRED = 2
UPDATE_RUNNING = 256
UPDATE_PAUSED = 512
UPDATE_STARTED = 1024
DOWNLOADING = 1048576


def read_vdf(path: Path) -> dict:
    try:
        return parse_vdf(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError, RuntimeError):
        return {}


def library_folders() -> list[Path]:
    folders = [STEAM]
    lf = read_vdf(STEAM / "steamapps/libraryfolders.vdf").get("libraryfolders", {})
    for v in lf.values():
        if isinstance(v, dict) and v.get("path"):
            p = Path(v["path"])
            if p not in folders:
                folders.append(p)
    return folders


def last_played() -> dict[str, int]:
    out: dict[str, int] = {}
    for cfg in (STEAM / "userdata").glob("*/config/localconfig.vdf"):
        root = read_vdf(cfg).get("UserLocalConfigStore", {})
        apps = root.get("Software", {}).get("Valve", {}).get("Steam", {}).get("apps", {})
        for appid, info in apps.items():
            if isinstance(info, dict) and info.get("LastPlayed", "").isdigit():
                out[appid] = max(out.get(appid, 0), int(info["LastPlayed"]))
    return out


def classify(flags: int) -> str:
    if flags & (DOWNLOADING | UPDATE_RUNNING):
        return "downloading"
    if flags & UPDATE_PAUSED:
        return "paused"
    if flags & (UPDATE_REQUIRED | UPDATE_STARTED):
        return "update-queued"
    if flags & FULLY_INSTALLED:
        return "installed"
    return "unknown"


def main() -> int:
    played = last_played()
    games = []
    for folder in library_folders():
        for acf in (folder / "steamapps").glob("appmanifest_*.acf"):
            st = read_vdf(acf).get("AppState", {})
            appid = st.get("appid")
            if not appid:
                continue
            try:
                flags = int(st.get("StateFlags", "0"))
            except ValueError:
                flags = 0
            def num(key):
                try:
                    return int(st.get(key, "0"))
                except ValueError:
                    return 0
            games.append({
                "appid": int(appid),
                "name": st.get("name", f"App {appid}"),
                "state": classify(flags),
                "state_flags": flags,
                "size_on_disk": num("SizeOnDisk"),
                "bytes_to_download": num("BytesToDownload"),
                "bytes_downloaded": num("BytesDownloaded"),
                "last_played": played.get(appid, num("LastPlayed")),
                "library": str(folder),
                "install_dir": st.get("installdir", ""),
            })
    # Steam's own runtimes/tools are apps too; flag them for the UI.
    tools = ("Proton", "Steam Linux Runtime", "Steamworks Common")
    for g in games:
        g["is_tool"] = any(g["name"].startswith(t) for t in tools)
    games.sort(key=lambda g: (-g["last_played"], g["name"].lower()))
    print(json.dumps({"steam_root": str(STEAM), "games": games}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
