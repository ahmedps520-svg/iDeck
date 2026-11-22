#!/usr/bin/env python3
"""Writes iDeck's update feed: a source for SideStore and AltStore.

  make_altsource.py --ipa build/iDeck-SideStore.ipa \
      --download-url https://github.com/OWNER/REPO/releases/download/ios-build-30/iDeck-SideStore.ipa \
      --source-url https://github.com/OWNER/REPO/releases/download/ios-feed/source.json \
      --icon-url https://github.com/OWNER/REPO/releases/download/ios-feed/icon.png \
      --website https://github.com/OWNER/REPO \
      [--previous old/source.json] [--notes "what changed"] [--date 2026-11-22T10:00:00Z] \
      --out build/source.json

  make_altsource.py --verify-url https://github.com/OWNER/REPO/releases/download/ios-feed/source.json

SideStore and AltStore compare the downloaded IPA with the feed and refuse
to install it on any mismatch. Everything they check is read from the IPA
itself, so the feed cannot disagree with it:

  version, buildVersion  CFBundleShortVersionString, CFBundleVersion
  size, sha256           of the IPA file
  appPermissions         entitlements in the code signature of the app and its
                         extensions, and every *UsageDescription key of their
                         Info.plists
  minOSVersion           MinimumOSVersion

The newest version comes first in `versions`; that is how both stores decide
what is latest. SideStore offers an update only when `version` increases
(a semantic version compare), so CI sets CFBundleShortVersionString to
0.1.<build number>.

--verify-url downloads the published feed and the IPA it points to, the way
SideStore does (following GitHub's redirects), and checks them against each
other.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
import struct
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

CHUNK = 1 << 22
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5
# Mach-O magics as read little-endian from the first four bytes.
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
# Fat headers are big-endian.
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

SOURCE_IDENTIFIER = "com.ideck.source"
DEFAULT_KEEP = 20
APP_DESCRIPTION = (
    "iDeck runs ARM64 Debian Linux in a QEMU virtual machine and starts Valve's own "
    "ARM64 Linux Steam client inside it. x86-64 games run through FEX, Windows games "
    "through Proton, and graphics go to Metal through virglrenderer, MoltenVK and ANGLE.\n\n"
    "Needs JIT: enable it with StikDebug every time you open iDeck. Linux itself (the "
    "runtime, about 380 MB) is downloaded by the app on first start.\n\n"
    "Compatibility differs from game to game, and many games will not run or will run "
    "slowly under emulation. iDeck is a personal project and is not affiliated with Valve."
)


class FeedError(Exception):
    pass


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(CHUNK), b""):
            h.update(c)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Mach-O code signature: entitlements


def _slices(data: bytes):
    """Yields (offset, size) of each thin Mach-O in data."""
    if len(data) < 8:
        return
    be = struct.unpack(">I", data[:4])[0]
    if be in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack(">I", data[4:8])[0]
        entry = 20 if be == FAT_MAGIC else 32
        for i in range(n):
            o = 8 + i * entry
            if be == FAT_MAGIC:
                _cpu, _sub, off, size, _align = struct.unpack(">iiIII", data[o:o + 20])
            else:
                _cpu, _sub, off, size, _align, _res = struct.unpack(">iiQQII", data[o:o + 32])
            yield off, size
    else:
        yield 0, len(data)


def _thin_entitlements(m: bytes) -> dict:
    magic = struct.unpack("<I", m[:4])[0]
    if magic == MH_MAGIC_64:
        header = 32
    elif magic == MH_MAGIC:
        header = 28
    else:
        raise FeedError(f"not a Mach-O file (magic {magic:#x})")
    ncmds = struct.unpack("<I", m[16:20])[0]
    off = header
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", m[off:off + 8])
        if size < 8:
            raise FeedError("malformed Mach-O load command")
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack("<II", m[off + 8:off + 16])
            return _superblob_entitlements(m[dataoff:dataoff + datasize])
        off += size
    return {}  # unsigned


def _superblob_entitlements(sig: bytes) -> dict:
    if len(sig) < 12:
        raise FeedError("code signature is truncated")
    magic, _length, count = struct.unpack(">III", sig[:12])
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise FeedError(f"unexpected code signature magic {magic:#x}")
    for i in range(count):
        slot, blob_off = struct.unpack(">II", sig[12 + i * 8:20 + i * 8])
        if slot != CSSLOT_ENTITLEMENTS:
            continue
        bmagic, blen = struct.unpack(">II", sig[blob_off:blob_off + 8])
        if bmagic != CSMAGIC_EMBEDDED_ENTITLEMENTS:
            raise FeedError(f"unexpected entitlements blob magic {bmagic:#x}")
        ent = plistlib.loads(sig[blob_off + 8:blob_off + blen])
        if not isinstance(ent, dict):
            raise FeedError("entitlements are not a dictionary")
        return ent
    return {}  # signed without entitlements


def macho_entitlements(data: bytes) -> dict:
    """Entitlements embedded in a (thin or fat) Mach-O; {} when unsigned.

    Fat binaries: the slices' entitlements are merged (they are the same in
    practice)."""
    merged: dict = {}
    for off, size in _slices(data):
        merged.update(_thin_entitlements(data[off:off + size]))
    return merged


# ---------------------------------------------------------------------------
# IPA


def _bundles(z: zipfile.ZipFile):
    """Yields (bundle_dir, info_plist) for the app and each app extension."""
    names = z.namelist()
    apps = sorted({m.group(1) for n in names if (m := re.match(r"^(Payload/[^/]+\.app)/Info\.plist$", n))})
    if len(apps) != 1:
        raise FeedError(f"expected one Payload/*.app in the IPA, found {len(apps)}")
    app = apps[0]
    yield app, plistlib.loads(z.read(app + "/Info.plist"))
    ext_re = re.compile(r"^(" + re.escape(app) + r"/(?:PlugIns|Extensions)/[^/]+\.appex)/Info\.plist$")
    for n in sorted(names):
        if m := ext_re.match(n):
            yield m.group(1), plistlib.loads(z.read(n))


def read_ipa(path: Path) -> dict:
    """What SideStore and AltStore compare against the feed."""
    entitlements: set = set()
    privacy: dict = {}
    main = None
    with zipfile.ZipFile(path) as z:
        for bundle, info in _bundles(z):
            exe = info.get("CFBundleExecutable")
            if not exe:
                raise FeedError(f"{bundle}/Info.plist has no CFBundleExecutable")
            ent = macho_entitlements(z.read(f"{bundle}/{exe}"))
            entitlements.update(ent)
            for k, v in info.items():
                if "UsageDescription" in k and isinstance(v, str):
                    privacy.setdefault(k, v)
            if main is None:
                main = {"info": info, "entitlements": ent}
    info = main["info"]
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if not info.get(key) or "$(" in str(info[key]):
            raise FeedError(f"Info.plist {key} is missing or unexpanded: {info.get(key)!r}")
    # Both stores ignore these two; listing them would only add noise.
    entitlements -= {"application-identifier", "com.apple.developer.team-identifier"}
    return {
        "bundle_id": info["CFBundleIdentifier"],
        "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or "iDeck",
        "version": str(info["CFBundleShortVersionString"]),
        "build": str(info["CFBundleVersion"]),
        "min_os": info.get("MinimumOSVersion"),
        "entitlements": sorted(entitlements),
        "main_entitlements": main["entitlements"],
        "privacy": dict(sorted(privacy.items())),
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
    }


# ---------------------------------------------------------------------------
# Source


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def version_entry(ipa: dict, download_url: str, date: str, notes: str) -> dict:
    entry = {
        "version": ipa["version"],
        "buildVersion": ipa["build"],
        "marketingVersion": f"{ipa['version']} (build {ipa['build']})",
        "date": date,
        "localizedDescription": notes,
        "downloadURL": download_url,
        "size": ipa["size"],
        "sha256": ipa["sha256"],
    }
    if ipa["min_os"]:
        entry["minOSVersion"] = ipa["min_os"]
    return entry


def build_source(ipa: dict, entry: dict, previous: dict | None, *, source_url: str, icon_url: str,
                 website: str, keep: int = DEFAULT_KEEP) -> dict:
    """The new source: the previous one's versions of this app, with `entry`
    first. An entry for the same version and build is replaced."""
    old_versions = []
    if previous:
        for app in previous.get("apps", []):
            if app.get("bundleIdentifier") == ipa["bundle_id"]:
                old_versions = [v for v in app.get("versions", []) if isinstance(v, dict)]
    versions = [entry] + [v for v in old_versions
                          if (v.get("version"), v.get("buildVersion")) != (entry["version"], entry["buildVersion"])]
    versions = versions[:max(1, keep)]
    app = {
        "name": ipa["name"],
        "bundleIdentifier": ipa["bundle_id"],
        "developerName": "iDeck",
        "subtitle": "Linux and the Steam client in a virtual machine",
        "localizedDescription": APP_DESCRIPTION,
        "iconURL": icon_url,
        "tintColor": "#5CCCFF",
        "category": "games",
        "versions": versions,
        "appPermissions": {
            "entitlements": list(ipa["entitlements"]),
            "privacy": dict(ipa["privacy"]),
        },
        # Pre-2.0 AltStore and old SideStore releases read only these.
        "version": entry["version"],
        "versionDate": entry["date"],
        "versionDescription": entry["localizedDescription"],
        "downloadURL": entry["downloadURL"],
        "size": entry["size"],
    }
    source = {
        "name": "iDeck",
        "identifier": SOURCE_IDENTIFIER,
        "subtitle": "Builds of iDeck from its GitHub repository",
        "description": "Every iDeck build published from the repository's iOS workflow. "
                       "The IPA is the SideStore/AltStore edition, which declares the app group that Vulkan uses.",
        "iconURL": icon_url,
        "website": website,
        "tintColor": "#5CCCFF",
        # SideStore checks the IPA's permissions against appPermissions only for
        # sources of version 2 or later.
        "version": 2,
        "apps": [app],
        "news": [],
    }
    if source_url:
        source["sourceURL"] = source_url
    return source


def check_source(source: dict, ipa: dict) -> list:
    """Problems that would make SideStore or AltStore refuse the IPA."""
    problems = []
    apps = [a for a in source.get("apps", []) if a.get("bundleIdentifier") == ipa["bundle_id"]]
    if len(apps) != 1:
        return [f"source lists {len(apps)} apps with bundle identifier {ipa['bundle_id']}"]
    app = apps[0]
    for key in ("name", "bundleIdentifier", "developerName", "localizedDescription", "iconURL", "versions"):
        if not app.get(key):
            problems.append(f"app key {key} is missing")
    latest = (app.get("versions") or [{}])[0]
    for key, want in (("version", ipa["version"]), ("buildVersion", ipa["build"]),
                      ("size", ipa["size"]), ("sha256", ipa["sha256"])):
        if latest.get(key) != want:
            problems.append(f"latest {key} is {latest.get(key)!r}, the IPA has {want!r}")
    perms = app.get("appPermissions") or {}
    missing_ent = sorted(set(ipa["entitlements"]) - set(perms.get("entitlements") or []))
    missing_priv = sorted(set(ipa["privacy"]) - set((perms.get("privacy") or {}).keys()))
    if missing_ent:
        problems.append(f"entitlements not declared: {missing_ent}")
    if missing_priv:
        problems.append(f"privacy permissions not declared: {missing_priv}")
    try:
        dt.datetime.fromisoformat(str(latest.get("date", "")).replace("Z", "+00:00"))
    except ValueError:
        problems.append(f"date {latest.get('date')!r} is not ISO 8601")
    seen = set()
    for v in app.get("versions", []):
        k = (v.get("version"), v.get("buildVersion"))
        if k in seen:
            problems.append(f"version {k} is listed twice")
        seen.add(k)
    return problems


# ---------------------------------------------------------------------------
# Verification of the published feed


def _fetch(url: str, dest: Path | None = None) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": "ideck-feed-check"})
    with urllib.request.urlopen(req, timeout=120) as r:
        if dest is None:
            return r.read()
        with open(dest, "wb") as f:
            for c in iter(lambda: r.read(CHUNK), b""):
                f.write(c)
    return None


def verify_url(url: str, expect_version: str = "") -> dict:
    source = json.loads(_fetch(url).decode("utf-8"))
    app = source["apps"][0]
    latest = app["versions"][0]
    with tempfile.TemporaryDirectory() as tmp:
        ipa_path = Path(tmp) / "app.ipa"
        _fetch(latest["downloadURL"], ipa_path)
        ipa = read_ipa(ipa_path)
    problems = check_source(source, ipa)
    if expect_version and ipa["version"] != expect_version:
        problems.append(f"latest version is {ipa['version']}, expected {expect_version}")
    if problems:
        raise FeedError("published feed does not match its IPA: " + "; ".join(problems))
    return {"version": ipa["version"], "build": ipa["build"], "size": ipa["size"],
            "sha256": ipa["sha256"], "entitlements": ipa["entitlements"],
            "privacy": list(ipa["privacy"]), "versions_listed": len(app["versions"])}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ipa", type=Path)
    ap.add_argument("--download-url")
    ap.add_argument("--source-url", default="")
    ap.add_argument("--icon-url")
    ap.add_argument("--website", default="")
    ap.add_argument("--previous", type=Path, help="the currently published source.json, if any")
    ap.add_argument("--notes", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--keep", type=int, default=DEFAULT_KEEP, help="versions to keep in the feed")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--require-entitlement", action="append", default=[],
                    help="fail unless the main executable is signed with this entitlement")
    ap.add_argument("--print-ipa", action="store_true", help="print what was read from --ipa and exit")
    ap.add_argument("--verify-url", help="check a published feed against the IPA it points to")
    ap.add_argument("--expect-version", default="", help="with --verify-url: the version that must be latest")
    a = ap.parse_args(argv)

    try:
        if a.verify_url:
            print(json.dumps(verify_url(a.verify_url, a.expect_version), indent=2))
            return 0
        if not a.ipa:
            ap.error("--ipa is required")
        ipa = read_ipa(a.ipa)
        missing = [e for e in a.require_entitlement if e not in ipa["main_entitlements"]]
        if missing:
            raise FeedError(f"{a.ipa} is not signed with {missing}; signed entitlements: "
                            f"{sorted(ipa['main_entitlements'])}")
        if a.print_ipa:
            print(json.dumps({k: v for k, v in ipa.items() if k != "main_entitlements"}, indent=2))
            return 0
        if not (a.download_url and a.icon_url and a.out):
            ap.error("--download-url, --icon-url and --out are required")
        previous = None
        if a.previous and a.previous.is_file():
            previous = json.loads(a.previous.read_text(encoding="utf-8"))
        notes = a.notes or f"Build {ipa['build']}."
        entry = version_entry(ipa, a.download_url, a.date or utc_now(), notes)
        source = build_source(ipa, entry, previous, source_url=a.source_url, icon_url=a.icon_url,
                              website=a.website, keep=a.keep)
        problems = check_source(source, ipa)
        if problems:
            raise FeedError("; ".join(problems))
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"{a.out}: {ipa['name']} {ipa['version']} (build {ipa['build']}), "
              f"{len(source['apps'][0]['versions'])} versions, entitlements {ipa['entitlements']}")
        return 0
    except FeedError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
