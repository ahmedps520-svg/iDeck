"""Tests for steam_prefs.py (Steam's library performance settings)."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "rootfs" / "usr" / "lib" / "ideck"))
import steam_prefs as sp  # noqa: E402

LOCALCONFIG = '''"UserLocalConfigStore"
{
\t"Broadcast"
\t{
\t\t"Permissions"\t\t"1"
\t}
\t"system"
\t{
\t\t"InGameOverlayShowFPSCorner"\t\t"0"
\t\t"LibraryLowPerfMode"\t\t"0"
\t}
\t"LibraryLowPerfMode"\t\t"0"
\t"friends"
\t{
\t\t"PersonaName"\t\t"a \\"quoted\\" name {not a brace}"
\t}
\t"ShowCopyCountInLibrary"\t\t"1"
}
'''


class SetRootValuesTests(unittest.TestCase):
    def test_replaces_existing_and_appends_missing(self):
        out = sp.set_root_values(LOCALCONFIG, sp.LIGHT)
        self.assertIn('\t"LibraryLowPerfMode"\t\t"1"\n\t"friends"', out)
        # The key of the same name inside "system" is not the root setting.
        self.assertIn('\t\t"LibraryLowPerfMode"\t\t"0"\n\t}', out)
        self.assertTrue(out.endswith('\t"ShowCopyCountInLibrary"\t\t"1"\n\t"LibraryLowBandwidthMode"\t\t"1"\n}\n'))
        # Everything else byte-for-byte, including the escaped quotes and braces in a string.
        self.assertIn('"a \\"quoted\\" name {not a brace}"', out)
        self.assertEqual(out.replace('"1"\n\t"friends"', '"0"\n\t"friends"')
                         .replace('\t"LibraryLowBandwidthMode"\t\t"1"\n', ''), LOCALCONFIG)

    def test_idempotent(self):
        once = sp.set_root_values(LOCALCONFIG, sp.LIGHT)
        self.assertEqual(sp.set_root_values(once, sp.LIGHT), once)

    def test_crlf_files_keep_crlf(self):
        text = LOCALCONFIG.replace("\n", "\r\n")
        out = sp.set_root_values(text, {"LibraryLowBandwidthMode": "1"})
        self.assertIn('\t"LibraryLowBandwidthMode"\t\t"1"\r\n}', out)
        self.assertNotIn("\r\r", out)

    def test_minimal_and_broken_files(self):
        self.assertEqual(sp.set_root_values('"UserLocalConfigStore"\n{\n}\n', {"A": "1"}),
                         '"UserLocalConfigStore"\n{\n\t"A"\t\t"1"\n}\n')
        with self.assertRaises(ValueError):
            sp.set_root_values('"SomethingElse"\n{\n}\n', {"A": "1"})
        with self.assertRaises(ValueError):
            sp.set_root_values('"UserLocalConfigStore"\n{\n\t"A"\t\t"0"\n', {"A": "1"})

    def test_apply_writes_every_user_and_skips_broken(self):
        with tempfile.TemporaryDirectory() as tmp:
            steam = Path(tmp)
            good = steam / "userdata" / "123" / "config" / "localconfig.vdf"
            bad = steam / "userdata" / "456" / "config" / "localconfig.vdf"
            for p in (good, bad):
                p.parent.mkdir(parents=True)
            good.write_text(LOCALCONFIG, encoding="utf-8")
            bad.write_text("garbage", encoding="utf-8")
            changed = sp.apply(sp.LIGHT, steam)
            self.assertEqual(changed, [str(good)])
            self.assertIn('"LibraryLowBandwidthMode"\t\t"1"', good.read_text(encoding="utf-8"))
            self.assertEqual(bad.read_text(encoding="utf-8"), "garbage")
            self.assertEqual(sp.apply(sp.LIGHT, steam), [])   # nothing to change the second time


if __name__ == "__main__":
    unittest.main()
