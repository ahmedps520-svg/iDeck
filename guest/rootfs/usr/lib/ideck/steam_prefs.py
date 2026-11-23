#!/usr/bin/env python3
"""Sets Steam's library performance settings before the client starts.

  steam_prefs.py --light     (run by ideck-steam-launch as user deck)

Steam's client settings name their store and key (SteamDatabase/Protobufs,
steammessages_clientsettings.proto):

  library_low_perf_mode       ConfigStore_UserLocal  "LibraryLowPerfMode"
  library_low_bandwidth_mode  ConfigStore_UserLocal  "LibraryLowBandwidthMode"

The UserLocal store is userdata/<account>/config/localconfig.vdf, root key
"UserLocalConfigStore"; names without a "system\\" style prefix sit directly
under the root. Low Performance Mode turns off the library's animations,
blur and trailers; Low Bandwidth Mode loads smaller images and no animated
content. Under emulation those are the most expensive things Steam's
software-drawn UI does (Skia's floating-point raster and image decoding).

Only these keys are changed. The rest of the file keeps its exact bytes, so
nothing Steam wrote is reformatted or lost. Steam reads the file at start
and writes it back on exit with the values it loaded.
"""
import argparse
import os
import sys
import tempfile
from pathlib import Path

STEAM = Path.home() / ".local" / "share" / "Steam"
LIGHT = {"LibraryLowPerfMode": "1", "LibraryLowBandwidthMode": "1"}


def _tokens(text: str):
    """(kind, start, end, value) for "strings", { and }; skips // comments."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif c in "{}":
            yield (c, i, i + 1, c)
            i += 1
        elif c == '"':
            j, out = i + 1, []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    out.append(text[j:j + 2])
                    j += 2
                else:
                    out.append(text[j])
                    j += 1
            yield ("str", i, j + 1, "".join(out))
            i = j + 1
        else:  # unquoted token
            j = i
            while j < n and text[j] not in " \t\r\n{}\"":
                j += 1
            yield ("str", i, j, text[i:j])
            i = j


def set_root_values(text: str, values: dict, root: str = "UserLocalConfigStore") -> str:
    """Sets string values directly under `root`, keeping every other byte."""
    toks = list(_tokens(text))
    # Find `"root" {`.
    start = None
    for k in range(len(toks) - 1):
        if toks[k][0] == "str" and toks[k][3] == root and toks[k + 1][0] == "{":
            start = k + 2
            break
    if start is None:
        raise ValueError(f"no {root} block")
    edits = []  # (begin, end, replacement), applied back to front
    seen = set()
    depth = 1
    k = start
    close_at = None
    while k < len(toks):
        kind, b, e, val = toks[k]
        if kind == "}":
            depth -= 1
            if depth == 0:
                close_at = b
                break
            k += 1
        elif kind == "{":
            depth += 1
            k += 1
        elif depth == 1 and k + 1 < len(toks) and toks[k + 1][0] == "str":
            # key "value" at the root level
            if val in values:
                vb, ve = toks[k + 1][1], toks[k + 1][2]
                edits.append((vb, ve, f'"{values[val]}"'))
                seen.add(val)
            k += 2
        else:
            k += 1
    if close_at is None:
        raise ValueError(f"unterminated {root} block")
    missing = [key for key in values if key not in seen]
    if missing:
        nl = "\r\n" if "\r\n" in text else "\n"
        insert = "".join(f'\t"{key}"\t\t"{values[key]}"{nl}' for key in missing)
        # Before the closing brace, at the start of its line.
        line_start = text.rfind("\n", 0, close_at) + 1
        edits.append((line_start, line_start, insert))
    for b, e, rep in sorted(edits, reverse=True):
        text = text[:b] + rep + text[e:]
    return text


def apply(values: dict, steam: Path = STEAM) -> list:
    changed = []
    for cfg in sorted((steam / "userdata").glob("*/config/localconfig.vdf")):
        try:
            old = cfg.read_text(encoding="utf-8")
            new = set_root_values(old, values)
        except (OSError, UnicodeDecodeError, ValueError) as e:
            print(f"steam_prefs: {cfg}: {e}", file=sys.stderr)
            continue
        if new != old:
            fd, tmp = tempfile.mkstemp(dir=cfg.parent, prefix=".localconfig.")
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                f.write(new)
            os.replace(tmp, cfg)
            changed.append(str(cfg))
    return changed


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--light", action="store_true", help="Low Performance and Low Bandwidth library modes on")
    a = ap.parse_args(argv)
    if a.light:
        for path in apply(LIGHT):
            print(f"steam_prefs: light library settings written to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
