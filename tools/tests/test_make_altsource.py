"""Tests for tools/make_altsource.py (the SideStore / AltStore feed)."""
import hashlib
import json
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import make_altsource as m  # noqa: E402

ENTITLEMENTS = {
    "application-identifier": "TEAM.com.ideck.app",
    "get-task-allow": True,
    "com.apple.security.application-groups": ["group.ideck"],
    "com.apple.developer.kernel.increased-memory-limit": True,
}


def superblob(entitlements):
    xml = plistlib.dumps(entitlements, fmt=plistlib.FMT_XML)
    code_dir = struct.pack(">II", 0xFADE0C02, 8)
    ent = struct.pack(">II", m.CSMAGIC_EMBEDDED_ENTITLEMENTS, 8 + len(xml)) + xml
    header_len = 12 + 2 * 8
    blobs = [(0, code_dir), (m.CSSLOT_ENTITLEMENTS, ent)]
    index, body, off = b"", b"", header_len
    for slot, blob in blobs:
        index += struct.pack(">II", slot, off)
        body += blob
        off += len(blob)
    return struct.pack(">III", m.CSMAGIC_EMBEDDED_SIGNATURE, off, len(blobs)) + index + body


def thin_macho(entitlements=None):
    """A minimal arm64 executable header, signed when entitlements is given."""
    if entitlements is None:
        lc = struct.pack("<II", 0x19, 8)  # some other load command
        return struct.pack("<IiiIIIII", m.MH_MAGIC_64, 0x0100000C, 0, 2, 1, len(lc), 0, 0) + lc + b"\0" * 64
    sig = superblob(entitlements)
    dataoff = 256
    lc = struct.pack("<IIII", m.LC_CODE_SIGNATURE, 16, dataoff, len(sig))
    head = struct.pack("<IiiIIIII", m.MH_MAGIC_64, 0x0100000C, 0, 2, 1, len(lc), 0, 0) + lc
    return head + b"\0" * (dataoff - len(head)) + sig


def fat_macho(thin):
    off = 4096
    head = struct.pack(">II", m.FAT_MAGIC, 1) + struct.pack(">iiIII", 0x0100000C, 0, off, len(thin), 12)
    return head + b"\0" * (off - len(head)) + thin


def make_ipa(path, *, version="0.1.30", build="30", entitlements=ENTITLEMENTS, extension=False, fat=False):
    info = {
        "CFBundleIdentifier": "com.ideck.app",
        "CFBundleDisplayName": "iDeck",
        "CFBundleExecutable": "iDeck",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": "17.0",
        "NSMicrophoneUsageDescription": "Linux games can use the microphone.",
        "NSLocalNetworkUsageDescription": "Local sockets.",
    }
    exe = thin_macho(entitlements)
    if fat:
        exe = fat_macho(exe)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/iDeck.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        z.writestr("Payload/iDeck.app/iDeck", exe)
        z.writestr("Payload/iDeck.app/Frameworks/QEMU.framework/QEMU", b"\xcf\xfa\xed\xfe")
        if extension:
            ext_info = {"CFBundleExecutable": "Widget", "NSCameraUsageDescription": "Widget camera."}
            z.writestr("Payload/iDeck.app/PlugIns/Widget.appex/Info.plist", plistlib.dumps(ext_info))
            z.writestr("Payload/iDeck.app/PlugIns/Widget.appex/Widget",
                       thin_macho({"com.apple.developer.siri": True}))
    return path


class MachOTests(unittest.TestCase):
    def test_unsigned_binary_has_no_entitlements(self):
        self.assertEqual(m.macho_entitlements(thin_macho(None)), {})

    def test_signed_thin_binary(self):
        self.assertEqual(m.macho_entitlements(thin_macho(ENTITLEMENTS)), ENTITLEMENTS)

    def test_signed_fat_binary(self):
        self.assertEqual(m.macho_entitlements(fat_macho(thin_macho(ENTITLEMENTS))), ENTITLEMENTS)

    def test_not_a_macho(self):
        with self.assertRaises(m.FeedError):
            m.macho_entitlements(b"#!/bin/sh\necho hi\n")


class IpaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_read_ipa(self):
        p = make_ipa(self.dir / "a.ipa")
        ipa = m.read_ipa(p)
        self.assertEqual((ipa["bundle_id"], ipa["version"], ipa["build"], ipa["min_os"]),
                         ("com.ideck.app", "0.1.30", "30", "17.0"))
        # application-identifier is set by the stores themselves and not listed.
        self.assertEqual(ipa["entitlements"], ["com.apple.developer.kernel.increased-memory-limit",
                                               "com.apple.security.application-groups", "get-task-allow"])
        self.assertEqual(list(ipa["privacy"]), ["NSLocalNetworkUsageDescription", "NSMicrophoneUsageDescription"])
        self.assertEqual(ipa["size"], p.stat().st_size)
        self.assertEqual(ipa["sha256"], hashlib.sha256(p.read_bytes()).hexdigest())

    def test_fat_executable_and_extensions_are_included(self):
        ipa = m.read_ipa(make_ipa(self.dir / "a.ipa", extension=True, fat=True))
        self.assertIn("com.apple.developer.siri", ipa["entitlements"])
        self.assertIn("NSCameraUsageDescription", ipa["privacy"])
        self.assertNotIn("com.apple.developer.siri", ipa["main_entitlements"])

    def test_unexpanded_build_setting_is_rejected(self):
        with self.assertRaises(m.FeedError):
            m.read_ipa(make_ipa(self.dir / "a.ipa", version="$(MARKETING_VERSION)"))

    def test_unsigned_ipa_declares_no_entitlements(self):
        ipa = m.read_ipa(make_ipa(self.dir / "a.ipa", entitlements=None))
        self.assertEqual(ipa["entitlements"], [])


class SourceTests(unittest.TestCase):
    URLS = dict(source_url="https://example.invalid/source.json", icon_url="https://example.invalid/icon.png",
                website="https://example.invalid/")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def source_for(self, build, previous=None, keep=m.DEFAULT_KEEP):
        ipa = m.read_ipa(make_ipa(self.dir / f"b{build}.ipa", version=f"0.1.{build}", build=str(build)))
        entry = m.version_entry(ipa, f"https://example.invalid/{build}.ipa", f"2026-11-{build - 8:02d}T10:00:00Z",
                                f"Build {build}.")
        return ipa, m.build_source(ipa, entry, previous, keep=keep, **self.URLS)

    def test_new_version_goes_first_and_matches_the_ipa(self):
        _, s30 = self.source_for(30)
        ipa, s31 = self.source_for(31, previous=s30)
        app = s31["apps"][0]
        self.assertEqual([v["buildVersion"] for v in app["versions"]], ["31", "30"])
        self.assertEqual(m.check_source(s31, ipa), [])
        self.assertEqual(s31["version"], 2)
        self.assertEqual(app["version"], "0.1.31")          # legacy keys mirror the latest
        self.assertEqual(app["downloadURL"], "https://example.invalid/31.ipa")
        self.assertEqual(app["appPermissions"]["privacy"]["NSMicrophoneUsageDescription"],
                         "Linux games can use the microphone.")

    def test_republishing_a_build_replaces_its_entry(self):
        _, s30 = self.source_for(30)
        _, again = self.source_for(30, previous=s30)
        self.assertEqual(len(again["apps"][0]["versions"]), 1)

    def test_keep_limits_the_history(self):
        s = None
        for b in range(20, 26):
            _, s = self.source_for(b, previous=s, keep=3)
        self.assertEqual([v["buildVersion"] for v in s["apps"][0]["versions"]], ["25", "24", "23"])

    def test_other_apps_in_previous_are_not_carried_over(self):
        prev = {"apps": [{"bundleIdentifier": "com.other.app", "versions": [{"version": "9", "buildVersion": "9"}]}]}
        _, s = self.source_for(30, previous=prev)
        self.assertEqual(len(s["apps"]), 1)
        self.assertEqual(len(s["apps"][0]["versions"]), 1)

    def test_check_source_finds_mismatches(self):
        ipa, s = self.source_for(30)
        s["apps"][0]["appPermissions"]["entitlements"].remove("get-task-allow")
        s["apps"][0]["versions"][0]["sha256"] = "0" * 64
        problems = m.check_source(s, ipa)
        self.assertTrue(any("get-task-allow" in p for p in problems), problems)
        self.assertTrue(any("sha256" in p for p in problems), problems)

    def test_semantic_versions_increase_with_the_build(self):
        # SideStore compares `version` as major.minor.patch.
        _, s = self.source_for(30)
        _, s = self.source_for(31, previous=s)
        vs = [tuple(int(x) for x in v["version"].split(".")) for v in s["apps"][0]["versions"]]
        self.assertEqual(vs, sorted(vs, reverse=True))


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_the_source(self):
        ipa = make_ipa(self.dir / "iDeck-SideStore.ipa")
        out = self.dir / "feed" / "source.json"
        rc = m.main(["--ipa", str(ipa), "--download-url", "https://example.invalid/x.ipa",
                     "--icon-url", "https://example.invalid/icon.png", "--out", str(out),
                     "--previous", str(self.dir / "missing.json"), "--date", "2026-11-22T10:00:00Z",
                     "--require-entitlement", "get-task-allow"])
        self.assertEqual(rc, 0)
        src = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(src["apps"][0]["versions"][0]["date"], "2026-11-22T10:00:00Z")

    def test_required_entitlement_missing_fails(self):
        ipa = make_ipa(self.dir / "iDeck.ipa", entitlements=None)
        rc = m.main(["--ipa", str(ipa), "--print-ipa", "--require-entitlement", "get-task-allow"])
        self.assertEqual(rc, 1)


class VerifyUrlTests(unittest.TestCase):
    """--verify-url against a local web server, with a redirect like GitHub's."""

    def setUp(self):
        import functools
        import http.server
        import threading

        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/download/"):
                    self.send_response(302)
                    self.send_header("Location", "/assets/" + self.path.rsplit("/", 1)[1])
                    self.end_headers()
                    return
                if self.path.startswith("/assets/"):
                    self.path = "/" + self.path.rsplit("/", 1)[1]
                super().do_GET()

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(Handler, directory=str(self.dir)))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def publish(self, ipa_name="iDeck-SideStore.ipa"):
        make_ipa(self.dir / "iDeck-SideStore.ipa")
        rc = m.main(["--ipa", str(self.dir / "iDeck-SideStore.ipa"),
                     "--download-url", f"{self.base}/download/{ipa_name}",
                     "--icon-url", f"{self.base}/icon.png", "--out", str(self.dir / "source.json")])
        self.assertEqual(rc, 0)

    def test_published_feed_matches(self):
        self.publish()
        result = m.verify_url(f"{self.base}/download/source.json", expect_version="0.1.30")
        self.assertEqual((result["version"], result["build"]), ("0.1.30", "30"))

    def test_wrong_expected_version_fails(self):
        self.publish()
        with self.assertRaises(m.FeedError):
            m.verify_url(f"{self.base}/download/source.json", expect_version="0.1.31")

    def test_replaced_ipa_fails(self):
        self.publish()
        make_ipa(self.dir / "iDeck-SideStore.ipa", entitlements=None)  # different bytes, no entitlements
        with self.assertRaises(m.FeedError):
            m.verify_url(f"{self.base}/download/source.json")


class EntitlementsFileTests(unittest.TestCase):
    def test_sidestore_entitlements(self):
        path = ROOT / "ios/iDeck/Support/iDeck-SideStore.entitlements"
        ent = plistlib.loads(path.read_bytes())
        self.assertIs(ent["get-task-allow"], True)
        groups = ent["com.apple.security.application-groups"]
        self.assertEqual(len(groups), 1)
        # SideStore and AltStore rename the group to "<group>.<10-character team ID>".
        # IDPlatform.m allows at most PSHMNAMLEN (31) - 3 characters for shm_open names.
        self.assertLessEqual(len(groups[0] + ".ABCDE12345"), 28, groups[0])
        self.assertFalse(any("$(" in g for g in groups))


if __name__ == "__main__":
    unittest.main()
