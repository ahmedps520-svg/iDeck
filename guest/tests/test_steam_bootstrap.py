"""Tests for the ARM64 Steam bootstrapper, using a local fake CDN.

Run: python -m unittest discover -s guest/tests
"""
import hashlib
import io
import json
import lzma
import os
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rootfs" / "usr" / "lib" / "ideck"))
import steam_bootstrap as sb  # noqa: E402

ELF_AARCH64 = b"\x7fELF\x02\x01\x01" + b"\0" * 9 + b"\x02\x00\xb7\x00" + b"\0" * 40
ELF_X86_64 = b"\x7fELF\x02\x01\x01" + b"\0" * 9 + b"\x02\x00\x3e\x00" + b"\0" * 40


def make_zip(entries: dict) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)
    return buf.getvalue()


def make_vz(data: bytes) -> bytes:
    """Valve VZ container as served by the CDN: "VZa", stamp, 5 LZMA
    properties, LZMA data with end marker, CRC-32, size, "zv"."""
    alone = lzma.compress(data, format=lzma.FORMAT_ALONE)  # props, size (-1), data
    return (b"VZa" + struct.pack("<I", 0x5FAB0AAD) + alone[:5] + alone[13:]
            + struct.pack("<II", zlib.crc32(data), len(data)) + b"zv")


class FakeResponse:
    def __init__(self, data: bytes, status: int = 200):
        self._buf = io.BytesIO(data)
        self.status = status

    def read(self, n=-1):
        return self._buf.read(n)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeCDN:
    """Serves files by URL and honours Range requests."""

    def __init__(self):
        self.files = {}
        self.requests = []

    def add(self, url, data):
        self.files[url] = data

    def __call__(self, req, timeout=None):
        url = req.full_url
        self.requests.append((url, req.get_header("Range")))
        data = self.files[url]
        rng = req.get_header("Range")
        if rng:
            start = int(rng.split("=")[1].rstrip("-"))
            return FakeResponse(data[start:], 206)
        return FakeResponse(data)


def manifest_for(pkgs: dict) -> str:
    lines = ['"linuxarm64"', "{", '\t"version"\t\t"1792618285"']
    for name, (fname, data, extra) in pkgs.items():
        lines += [f'\t"{name}"', "\t{", f'\t\t"file"\t\t"{fname}"', f'\t\t"size"\t\t"{len(data)}"',
                  f'\t\t"sha2"\t\t"{hashlib.sha256(data).hexdigest()}"']
        lines += [f'\t\t"{k}"\t\t"{v}"' for k, v in extra.items()]
        lines.append("\t}")
    lines += ["}", '"kvsign2"', "{", '\t"linuxarm64"\t\t"00"', "}"]
    return "\n".join(lines)


class VdfTests(unittest.TestCase):
    def test_nested_and_escapes(self):
        v = sb.parse_vdf('// c\n"a" { "b" "x\\"y" "c" { "d" "1" } [$LINUX] }\n"e" "f"')
        self.assertEqual(v["a"]["b"], 'x"y')
        self.assertEqual(v["a"]["c"]["d"], "1")
        self.assertEqual(v["e"], "f")

    def test_unbalanced(self):
        with self.assertRaises(sb.BootstrapError):
            sb.parse_vdf('"a" { "b" "c"')
        with self.assertRaises(sb.BootstrapError):
            sb.parse_vdf('"a" "b" }')

    def test_selection_order_and_missing(self):
        pkgs = {
            "bins_linuxarm64_linuxarm64": {"file": "b", "size": "1", "sha2": "0" * 64},
            "steam_linuxarm64": {"file": "s", "size": "1", "sha2": "0" * 64, "IsBootstrapperPackage": "1"},
            "webkit_linuxarm64": {"file": "w", "size": "1", "sha2": "0" * 64},
            "bins_androidarm64_linuxarm64": {"file": "a", "size": "1", "sha2": "0" * 64},
        }
        self.assertEqual(sb.select_packages(pkgs, False), ["steam_linuxarm64", "bins_linuxarm64_linuxarm64"])
        full = sb.select_packages(pkgs, True)
        self.assertEqual(full[0], "steam_linuxarm64")
        self.assertEqual(full[-1], "bins_linuxarm64_linuxarm64")
        self.assertNotIn("bins_androidarm64_linuxarm64", full)
        del pkgs["steam_linuxarm64"]
        with self.assertRaises(sb.BootstrapError):
            sb.select_packages(pkgs, False)


@unittest.skipIf(os.name == "nt", "symlinks and exec bits need a POSIX filesystem")
class BootstrapPosixTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_end_to_end_install(self):
        boot = make_zip({"steam.sh": b"#!/bin/bash\necho hi\n", "ubuntu12_32/steam": b"\x7fELF32"})
        bins = make_zip({"steamrtarm64/steam": ELF_AARCH64, "steamrtarm64/icudtl.dat": b"data"})
        cdn = FakeCDN()
        m = manifest_for({
            "steam_linuxarm64": ("steam_linuxarm64.zip.aa", boot, {"IsBootstrapperPackage": "1"}),
            "bins_linuxarm64_linuxarm64": ("bins_la.zip.bb", bins, {}),
        })
        cdn.add("https://manifest.test/m", m.encode())
        cdn.add(f"{sb.CDN}/steam_linuxarm64.zip.aa", boot)
        cdn.add(f"{sb.CDN}/bins_la.zip.bb", bins)
        home = self.dir / "home"
        root = home / ".local/share/Steam"
        state = home / ".local/share/ideck/steam-bootstrap.json"
        result = sb.bootstrap(root, home, self.dir / "cache", beta=False, full=False,
                              manifest_url="https://manifest.test/m", opener=cdn, state_path=state)
        self.assertEqual(result["status"], "installed")
        self.assertTrue(sb.is_installed(root))
        # A minimal install must not count as installed for --check: the
        # client then never fetches CEF/SDL3/codecs (runtime 0.1.2 failure).
        self.assertFalse(sb.is_installed(root, state))
        self.assertEqual(json.loads(state.read_text())["mode"], "minimal")
        self.assertTrue(os.access(root / "steam.sh", os.X_OK))
        self.assertFalse(os.access(root / "steamrtarm64/icudtl.dat", os.X_OK))
        # No steamrt64 link and no steam.sh flag: steamrt64/ is Valve's
        # x86-64 runtime, never the ARM64 client.
        self.assertFalse((root / "steamrt64").exists() or (root / "steamrt64").is_symlink())
        self.assertEqual(Path(os.readlink(home / ".steam/root")), root)
        self.assertFalse((root / ".steam-enable-steamrt64-client").exists())
        self.assertEqual(json.loads(state.read_text())["version"], "1792618285")
        # No VZ copies listed: the plain zips stay in package/ for the client.
        self.assertTrue((root / "package/steam_linuxarm64.zip.aa").is_file())
        self.assertTrue((root / "package/bins_la.zip.bb").is_file())
        # Re-running is idempotent.
        sb.bootstrap(root, home, self.dir / "cache", beta=True, full=False,
                     manifest_url="https://manifest.test/m", opener=cdn, state_path=state)
        self.assertEqual((root / "package/beta").read_text().strip(), "publicbeta")


    def _full_set(self, cdn):
        boot = make_zip({"steam.sh": b"#!/bin/bash\necho hi\n"})
        x86 = make_zip({"steamrt64/steam": ELF_X86_64, "steamrt64/steamclient.so": ELF_X86_64})
        bins = make_zip({"steamrtarm64/steam": ELF_AARCH64, "steamrtarm64/steamclient.so": ELF_AARCH64})
        m = manifest_for({
            "steam_linuxarm64": ("steam_linuxarm64.zip.aa", boot, {"IsBootstrapperPackage": "1"}),
            "steam_steamrt_linuxarm64": ("steam_steamrt.zip.cc", x86, {}),
            "bins_linuxarm64_linuxarm64": ("bins_la.zip.bb", bins, {}),
        })
        cdn.add("https://manifest.test/m", m.encode())
        cdn.add(f"{sb.CDN}/steam_linuxarm64.zip.aa", boot)
        cdn.add(f"{sb.CDN}/steam_steamrt.zip.cc", x86)
        cdn.add(f"{sb.CDN}/bins_la.zip.bb", bins)

    def test_full_install_over_legacy_link(self):
        """Runtime 0.1.3 boot test: the full set ships a real steamrt64/
        (x86-64). Over an old steamrt64 -> steamrtarm64 link it must neither
        fail nor put x86-64 files into the ARM64 client."""
        cdn = FakeCDN()
        self._full_set(cdn)
        home = self.dir / "home"
        root = home / ".local/share/Steam"
        state = home / ".local/share/ideck/steam-bootstrap.json"
        (root / "steamrtarm64").mkdir(parents=True)
        (root / "steamrtarm64/stale.so").write_bytes(ELF_X86_64)
        os.symlink("steamrtarm64", root / "steamrt64")
        (root / ".steam-enable-steamrt64-client").touch()
        sb.bootstrap(root, home, self.dir / "cache", beta=False, full=True,
                     manifest_url="https://manifest.test/m", opener=cdn, state_path=state)
        self.assertTrue(sb.is_installed(root, state))
        self.assertFalse((root / "steamrt64").is_symlink())
        self.assertEqual(sb.elf_machine(root / "steamrt64/steam"), 0x3E)
        self.assertEqual(sb.elf_machine(root / "steamrtarm64/steam"), sb.EM_AARCH64)
        self.assertEqual(sb.elf_machine(root / "steamrtarm64/steamclient.so"), sb.EM_AARCH64)
        self.assertFalse((root / "steamrtarm64/stale.so").exists())
        self.assertFalse((root / ".steam-enable-steamrt64-client").exists())

    def test_retry_resumes_after_last_extracted_package(self):
        cdn = FakeCDN()
        self._full_set(cdn)
        home = self.dir / "home"
        root = home / ".local/share/Steam"
        state = home / ".local/share/ideck/steam-bootstrap.json"
        sb.bootstrap(root, home, self.dir / "cache", beta=False, full=True,
                     manifest_url="https://manifest.test/m", opener=cdn, state_path=state)
        st = json.loads(state.read_text())
        st["status"] = "failed"
        del st["packages"]["bins_linuxarm64_linuxarm64"]
        state.write_text(json.dumps(st))
        (root / "steamrtarm64/steam").unlink()
        cdn.requests.clear()
        sb.bootstrap(root, home, self.dir / "cache", beta=False, full=True,
                     manifest_url="https://manifest.test/m", opener=cdn, state_path=state)
        # The package files are already in package/: nothing is downloaded
        # again, and only the unrecorded package is extracted again.
        fetched = [u for u, _ in cdn.requests if "zip" in u]
        self.assertEqual(fetched, [])
        self.assertTrue(sb.is_installed(root, state))

    def test_full_install_keeps_package_files_for_the_client(self):
        """Device run 2026-11-12: the client's first start found none of its
        package/*.zip.vz.* files and downloaded the whole client again."""
        boot = make_zip({"steam.sh": b"#!/bin/bash\necho hi\n"})
        bins = make_zip({"steamrtarm64/steam": ELF_AARCH64})
        strings = make_zip({"public/strings.txt": b"hello"})
        android = make_zip({"androidarm64/lepton": ELF_AARCH64})
        boot_vz, bins_vz, android_vz = make_vz(boot), make_vz(bins), make_vz(android)

        def vz(name, data):
            return {"zipvz": f"{name}.zip.vz.1234_{len(data)}", "sha2vz": hashlib.sha256(data).hexdigest()}

        cdn = FakeCDN()
        m = manifest_for({
            "steam_linuxarm64": ("steam_linuxarm64.zip.aa", boot,
                                 {"IsBootstrapperPackage": "1", **vz("steam_linuxarm64", boot_vz)}),
            "strings_en_all": ("strings_en_all.zip.dd", strings, {}),  # no VZ copy listed
            "bins_androidarm64_linuxarm64": ("bins_android.zip.ee", android, vz("bins_android", android_vz)),
            "bins_linuxarm64_linuxarm64": ("bins_la.zip.bb", bins, vz("bins_la", bins_vz)),
        })
        cdn.add("https://manifest.test/m", m.encode())
        cdn.add(f"{sb.CDN}/steam_linuxarm64.zip.vz.1234_{len(boot_vz)}", boot_vz)
        cdn.add(f"{sb.CDN}/bins_la.zip.vz.1234_{len(bins_vz)}", bins_vz)
        cdn.add(f"{sb.CDN}/bins_android.zip.vz.1234_{len(android_vz)}", android_vz)
        cdn.add(f"{sb.CDN}/strings_en_all.zip.dd", strings)
        home = self.dir / "home"
        root = home / ".local/share/Steam"
        state = home / ".local/share/ideck/steam-bootstrap.json"
        cache = self.dir / "cache"
        (root / "package").mkdir(parents=True)
        (root / "package/bins_la.zip.vz.old_1").write_bytes(b"x")  # other client version
        (root / "package/steam_client_metrics.bin").write_bytes(b"m")  # the client's own file
        sb.bootstrap(root, home, cache, beta=False, full=True,
                     manifest_url="https://manifest.test/m", opener=cdn, state_path=state)
        self.assertTrue(sb.is_installed(root, state))
        kept = sorted(f.name for f in (root / "package").iterdir())
        self.assertEqual(kept, sorted([
            f"bins_android.zip.vz.1234_{len(android_vz)}", f"bins_la.zip.vz.1234_{len(bins_vz)}",
            f"steam_linuxarm64.zip.vz.1234_{len(boot_vz)}", "steam_client_metrics.bin", "strings_en_all.zip.dd"]))
        # VZ packages were not downloaded a second time as plain zips.
        fetched = [u for u, _ in cdn.requests if "zip" in u]
        self.assertNotIn(f"{sb.CDN}/bins_la.zip.bb", fetched)
        self.assertEqual(len(fetched), 4)
        self.assertEqual(sb.elf_machine(root / "steamrtarm64/steam"), sb.EM_AARCH64)
        self.assertEqual((root / "public/strings.txt").read_bytes(), b"hello")
        self.assertFalse((root / "androidarm64").exists())  # kept, not extracted
        self.assertFalse(cache.exists())

    def test_extract_refuses_symlinked_directory(self):
        root = self.dir / "root"
        (root / "real").mkdir(parents=True)
        os.symlink("real", root / "link")
        z = self.dir / "p.zip"
        z.write_bytes(make_zip({"link/f": b"x"}))
        with self.assertRaises(sb.BootstrapError):
            sb.extract(z, root)
        self.assertFalse((root / "real/f").exists())


class VzTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_decode_round_trip(self):
        # 20 MiB of zeros decode from one small input chunk, so the 8 MiB
        # output limit per call has to be drained in a loop.
        data = make_zip({"zeros": b"\0" * (20 << 20), "random": os.urandom(300000)})
        src = self.dir / "p.zip.vz.1_1"
        src.write_bytes(make_vz(data))
        self.assertEqual(sb.decode_vz(src, self.dir / "out.zip"), len(data))
        self.assertEqual((self.dir / "out.zip").read_bytes(), data)

    def test_decode_rejects_bad_crc_magic_and_truncation(self):
        good = make_vz(b"payload" * 1000)
        bad_crc = good[:-10] + struct.pack("<I", 0) + good[-6:]
        for blob in (bad_crc, b"XYa" + good[3:], good[:40] + good[-10:]):
            src = self.dir / "p.vz"
            src.write_bytes(blob)
            with self.assertRaises(sb.BootstrapError):
                sb.decode_vz(src, self.dir / "out.zip")
            self.assertFalse((self.dir / "out.zip").exists())

    def test_package_source_and_size(self):
        p = {"file": "a.zip.1", "size": "10", "sha2": "1" * 64,
             "zipvz": "a.zip.vz.abc_7", "sha2vz": "2" * 64}
        self.assertEqual(sb.package_source(p), ("a.zip.vz.abc_7", 7, "2" * 64, True))
        self.assertEqual(sb.package_source({"file": "a.zip.1", "size": "10", "sha2": "1" * 64}),
                         ("a.zip.1", 10, "1" * 64, False))
        self.assertIsNone(sb.vz_size("a.zip.vz.abc"))


class ElfTests(unittest.TestCase):
    def test_machine(self):
        with tempfile.TemporaryDirectory() as d:
            a, x, t = Path(d) / "a", Path(d) / "x", Path(d) / "t"
            a.write_bytes(ELF_AARCH64)
            x.write_bytes(ELF_X86_64)
            t.write_bytes(b"#!/bin/sh\n")
            self.assertEqual(sb.elf_machine(a), sb.EM_AARCH64)
            self.assertEqual(sb.elf_machine(x), 0x3E)
            self.assertIsNone(sb.elf_machine(t))
            self.assertIsNone(sb.elf_machine(Path(d) / "missing"))


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_resume_and_verify(self):
        data = os.urandom(300000)
        cdn = FakeCDN()
        cdn.add("https://x.test/f", data)
        dest = self.dir / "f.zip"
        (self.dir / "f.zip.part").write_bytes(data[:100000])
        sb.download("https://x.test/f", dest, len(data), hashlib.sha256(data).hexdigest(), opener=cdn)
        self.assertEqual(dest.read_bytes(), data)
        self.assertEqual(cdn.requests[-1][1], "bytes=100000-")

    def test_bad_hash_rejected(self):
        cdn = FakeCDN()
        cdn.add("https://x.test/f", b"evil")
        sb.time.sleep = lambda s: None  # no backoff in tests
        with self.assertRaises(sb.BootstrapError):
            sb.download("https://x.test/f", self.dir / "f", 4, "0" * 64, attempts=2, opener=cdn)
        self.assertFalse((self.dir / "f").exists())

    def test_zip_slip_rejected(self):
        z = self.dir / "bad.zip"
        z.write_bytes(make_zip({"../escape": b"x"}))
        with self.assertRaises(sb.BootstrapError):
            sb.extract(z, self.dir / "root")


class RealManifestFormatTests(unittest.TestCase):
    """Runs against a real manifest if one is supplied (CI fetches it)."""

    def test_real_manifest(self):
        path = os.environ.get("IDECK_STEAM_MANIFEST")
        if not path:
            self.skipTest("set IDECK_STEAM_MANIFEST to a downloaded steam_client_linuxarm64")
        version, pkgs = sb.client_packages(sb.parse_vdf(Path(path).read_text()))
        self.assertTrue(version.isdigit())
        names = sb.select_packages(pkgs, False)
        self.assertEqual(names, ["steam_linuxarm64", "bins_linuxarm64_linuxarm64"])
        self.assertEqual(pkgs["steam_linuxarm64"].get("IsBootstrapperPackage"), "1")
        # Valve lists a VZ copy (what the client keeps in package/) for the
        # client binaries.
        self.assertTrue(sb.package_source(pkgs["bins_linuxarm64_linuxarm64"])[3])

    def test_real_vz_package_matches_plain_zip(self):
        """Downloads the smallest package that has a VZ copy from Valve's CDN
        (both forms, each checked against the manifest's SHA-256) and checks
        the decoded VZ holds exactly the plain zip's files."""
        path = os.environ.get("IDECK_STEAM_MANIFEST")
        if not path or os.environ.get("IDECK_STEAM_FETCH") != "1":
            self.skipTest("set IDECK_STEAM_MANIFEST and IDECK_STEAM_FETCH=1")
        _, pkgs = sb.client_packages(sb.parse_vdf(Path(path).read_text()))
        with_vz = [p for p in pkgs.values() if sb.package_source(p)[3]]
        p = min(with_vz, key=lambda p: sb.package_source(p)[1])
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            kept, is_vz = sb.fetch_package(p, d / "package", d / "cache")
            self.assertTrue(is_vz)
            sb.download(f"{sb.CDN}/{p['file']}", d / "plain.zip", int(p["size"]), p["sha2"])
            sb.decode_vz(kept, d / "decoded.zip")
            with zipfile.ZipFile(d / "decoded.zip") as a, zipfile.ZipFile(d / "plain.zip") as b:
                self.assertEqual(sorted(a.namelist()), sorted(b.namelist()))
                for n in a.namelist():
                    self.assertEqual(a.read(n), b.read(n), n)


if __name__ == "__main__":
    unittest.main()
