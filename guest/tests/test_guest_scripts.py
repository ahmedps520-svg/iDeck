"""Tests for guest helper scripts that run inside Linux (library listing,
provisioning hash checks, kernel extraction)."""
import gzip
import importlib
import json
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "guest" / "rootfs" / "usr" / "lib" / "ideck"))
sys.path.insert(0, str(ROOT / "tools"))


class SteamLibraryTests(unittest.TestCase):
    def test_lists_installed_and_downloading(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            steam = home / ".local/share/Steam"
            apps = steam / "steamapps"
            apps.mkdir(parents=True)
            (apps / "libraryfolders.vdf").write_text('"libraryfolders" { "0" { "path" "%s" } }' % steam)
            (apps / "appmanifest_70.acf").write_text(
                '"AppState" { "appid" "70" "name" "Half-Life" "StateFlags" "4" "SizeOnDisk" "500" }')
            (apps / "appmanifest_620.acf").write_text(
                '"AppState" { "appid" "620" "name" "Portal 2" "StateFlags" "1026" '
                '"BytesToDownload" "1000" "BytesDownloaded" "250" }')
            (apps / "appmanifest_1493710.acf").write_text(
                '"AppState" { "appid" "1493710" "name" "Proton Experimental" "StateFlags" "4" }')
            cfg = steam / "userdata/1/config"
            cfg.mkdir(parents=True)
            (cfg / "localconfig.vdf").write_text(
                '"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" { "70" { "LastPlayed" "1700000000" } } } } } }')
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = str(home)
            try:
                import steam_library
                importlib.reload(steam_library)
                steam_library.STEAM = steam
                from io import StringIO
                buf, old = StringIO(), sys.stdout
                sys.stdout = buf
                try:
                    self.assertEqual(steam_library.main(), 0)
                finally:
                    sys.stdout = old
                out = json.loads(buf.getvalue())
            finally:
                if old_home is not None:
                    os.environ["HOME"] = old_home
            games = {g["appid"]: g for g in out["games"]}
            self.assertEqual(games[70]["state"], "installed")
            self.assertEqual(games[70]["last_played"], 1700000000)
            self.assertEqual(games[620]["state"], "update-queued")
            self.assertEqual(games[620]["bytes_downloaded"], 250)
            self.assertTrue(games[1493710]["is_tool"])
            self.assertEqual(out["games"][0]["appid"], 70)  # most recently played first


class ExtractKernelTests(unittest.TestCase):
    def _image(self):
        b = bytearray(0x100)
        b[0x38:0x3C] = b"ARM\x64"
        return bytes(b)

    def test_raw_gzip_and_zboot(self):
        import extract_kernel as ek
        img = self._image()
        self.assertEqual(ek.extract(img), img)
        self.assertEqual(ek.extract(gzip.compress(img)), img)
        payload = gzip.compress(img)
        hdr = bytearray(0x40)
        hdr[0:2] = b"MZ"
        hdr[4:8] = b"zimg"
        struct.pack_into("<II", hdr, 0x08, 0x40, len(payload))
        hdr[0x18:0x18 + 4] = b"gzip"
        self.assertEqual(ek.extract(bytes(hdr) + payload), img)
        with self.assertRaises(ValueError):
            ek.extract(b"\x00" * 128)


class ManifestToolTests(unittest.TestCase):
    def test_make_manifest_round_trip(self):
        import make_manifest as mm
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "Image").write_bytes(self._k())
            (d / "system.img").write_bytes(b"\0" * 65536 + b"data")
            out = d / "dist"
            sys.argv = ["make_manifest.py", "--version", "0.1.0", "--base-url", "https://example.org/r",
                        "--out", str(out), "--kernel", str(d / "Image"), "--system", str(d / "system.img")]
            self.assertEqual(mm.main(), 0)
            m = json.loads((out / "manifest.json").read_text())
            self.assertEqual(m["schema"], 1)
            self.assertEqual([a["role"] for a in m["artifacts"]], ["kernel", "system-disk"])
            sysart = m["artifacts"][1]
            self.assertTrue(sysart["sparse"])
            self.assertEqual(sysart["installed_size"], 65540)
            import lzma
            self.assertEqual(lzma.decompress((out / "system.img.xz").read_bytes())[-4:], b"data")

    @staticmethod
    def _k():
        b = bytearray(0x100)
        b[0x38:0x3C] = b"ARM\x64"
        return bytes(b)


if __name__ == "__main__":
    unittest.main()
