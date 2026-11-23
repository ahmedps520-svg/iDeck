"""Tests for the host-VFP pattern table and the engine test tools."""
import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

import compare  # noqa: E402
import hostvfp_spec as spec  # noqa: E402
import run_guest_tests as rgt  # noqa: E402


class PatternTable(unittest.TestCase):
    def test_table_is_consistent(self):
        spec.validate()

    def test_known_encodings_match_their_pattern(self):
        known = {
            0x1E622820: "FADD_s",       # fadd d0, d1, d2
            0x1E250883: "FMUL_s",       # fmul s3, s4, s5
            0x1F420C20: "FMADD_all",    # fmadd d0, d1, d2, d3
            0x1E612000: "FCMP",         # fcmp d0, d1
            0x1E602008: "FCMP_z",       # fcmp d0, #0.0
            0x1E780020: "FCVTZS_g",     # fcvtzs w0, d1
            0x9E620020: "SCVTF_g",      # scvtf d0, x1
            0x4E22D420: "FADD_v",       # fadd v0.4s, v1.4s, v2.4s
            0x4E62CC20: "FMLA_v",       # fmla v0.2d, v1.2d, v2.2d
            0x6E22DC20: "FMUL_v",       # fmul v0.4s, v1.4s, v2.4s
            0x1E61C020: "FSQRT_s",      # fsqrt d0, d1
            0x1E604020: "FMOV_s",       # fmov d0, d1
            0x1E60C020: "FABS_s",       # fabs d0, d1
            0x1E214020: "FNEG_s",       # fneg s0, s1
            0x1E22C020: "FCVT_s_ds",    # fcvt d0, s1
            0x1E624020: "FCVT_s_sd",    # fcvt s0, d1
            0x5E21D820: "SCVTF_f",      # scvtf s0, s1
            0x0E21D820: "SCVTF_vi",     # scvtf v0.2s, v1.2s
            0x4EA1B820: "FCVTZS_vi",    # fcvtzs v0.4s, v1.4s
            0x0EA1D820: "FRECPE_v",     # frecpe v0.2s, v1.2s
            0x1E7E0020: "FJCVTZS",      # fjcvtzs w0, d1
            0x4E284820: "AESE",         # aese v0.16b, v1.16b
            0x4E020020: "TBL_TBX",      # tbl v0.16b, {v1.16b}, v2.16b
        }
        for insn, name in known.items():
            pat = spec.lookup(insn)
            self.assertIsNotNone(pat, hex(insn))
            self.assertEqual(pat.name, name, hex(insn))

    def test_encodings_qemu_must_keep(self):
        for insn, what in {
            0x4EA28420: "add v0.4s, v1.4s, v2.4s (integer: TCG does it inline)",
            0x1EE22820: "fadd h0, h1, h2 (half precision)",
            0x0E62D420: "fadd with Q=0, sz=1 (unallocated)",
            0x1E620C20: "fcsel d0, d1, d2, eq",
            0x9E660020: "fmov x0, d1",
            0x1E201000: "fmov s0, #2.0",
            0x0FC09020: "fmul v0.1d by element (needs Q=1)",
        }.items():
            self.assertIsNone(spec.lookup(insn), what)

    def test_flags_follow_the_fields(self):
        by = {p.name: p for p in spec.PATTERNS}
        f = by["FADD_s"].flags
        self.assertEqual(f & 7, spec.VEC)
        self.assertTrue(f & spec.HV_RD and f & spec.HV_RN and f & spec.HV_RM and f & spec.HV_SCALAR)
        self.assertFalse(f & spec.HV_RD_IN)
        self.assertTrue(f & spec.HV_IN_LO)
        self.assertFalse(by["FADD_v"].flags & spec.HV_IN_LO)
        self.assertFalse(by["FADDP_s"].flags & spec.HV_IN_LO, "reads a two-element vector")
        self.assertFalse(by["FMUL_si_d"].flags & spec.HV_IN_LO, "reads an element by index")
        self.assertTrue(by["FMLA_v"].flags & spec.HV_RD_IN)
        self.assertEqual(by["FCMP"].flags & 7, spec.FLAGS_OUT)
        self.assertFalse(by["FCMP"].flags & spec.HV_RD)
        self.assertEqual(by["SCVTF_g"].flags & 7, spec.GPR_IN)
        self.assertFalse(by["SCVTF_g"].flags & spec.HV_RN)
        self.assertEqual(by["FCVTZS_g"].flags & 7, spec.GPR_OUT)
        self.assertFalse(by["FCVTZS_g"].flags & spec.HV_RD)
        self.assertEqual(by["AESE"].flags >> spec.HV_FEAT_SHIFT, spec.FEATS.index("AES"))

    def test_cases_are_allocated_and_use_the_test_register(self):
        cases = spec.cases()
        self.assertGreater(len(cases), 3000)
        self.assertEqual(len({c[0] for c in cases}), len(cases))
        for insn, idx, low in cases:
            pat = spec.PATTERNS[idx]
            self.assertIs(spec.lookup(insn), pat, hex(insn))
            if pat.kind in (spec.GPR_OUT, spec.GPR_OUT_FLAGS):
                self.assertEqual(insn & 31, spec.TEST_GPR)
            if pat.kind == spec.GPR_IN:
                self.assertEqual((insn >> 5) & 31, spec.TEST_GPR)
            if low and pat.field("d"):
                self.assertLess(insn & 31, 8, hex(insn))
            if low and pat.field("n"):
                self.assertLess((insn >> 5) & 31, 8, hex(insn))
        self.assertEqual({c[1] for c in cases}, set(range(len(spec.PATTERNS))))
        self.assertGreater(sum(c[2] for c in cases), 1500)

    def test_generated_files_are_current(self):
        header = (ROOT / "bench" / "fpcheck_cases.h").read_text(encoding="utf-8").replace("\r\n", "\n")
        self.assertEqual(header, spec.cases_c(), "run engine/hostvfp_spec.py --cases bench/fpcheck_cases.h")
        patch = (ROOT / "engine" / "qemu" / "0001-host-vfp.patch").read_text(encoding="utf-8")
        patch = patch.replace("\r\n", "\n")
        for line in spec.table_c().splitlines():
            if line.startswith("    {"):
                self.assertIn("+" + line + "\n", patch, "the patch's pattern table is out of date")


class GuestRunner(unittest.TestCase):
    def test_cpio_layout(self):
        data = rgt.cpio_newc([("bin", 0o040755, b""), ("init", 0o100755, b"#!/bin/sh\n")])
        self.assertEqual(len(data) % 512, 0)
        self.assertTrue(data.startswith(b"070701"))
        self.assertIn(b"TRAILER!!!", data)
        # name of the second entry starts on a 4-byte boundary after its header
        second = data.index(b"070701", 6)
        self.assertEqual(second % 4, 0)
        self.assertEqual(data[second + 110:second + 115], b"init\0")

    def test_initramfs_contains_the_binaries(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "busybox").write_bytes(b"BB")
            (d / "tool").write_bytes(b"TOOL")
            blob = gzip.decompress(rgt.build_initramfs(d / "busybox", [(d / "tool", "ideck-x")],
                                                       ROOT / "engine" / "guest_init.sh"))
        self.assertIn(b"ideck-x\0", blob)
        self.assertIn(b"bin/busybox\0", blob)
        self.assertIn(b"#!/bin/busybox sh\n", blob)
        self.assertNotIn(b"\r\n", blob)

    def test_sections(self):
        log = ("boot noise\r\n@@BEGIN fpcheck\r\n{\"fpcheck\": 1}\r\n@@END fpcheck 0\r\n"
               "@@BEGIN bench\r\nx\r\ny\r\n@@END bench 3\r\n@@DONE\r\n")
        s = rgt.split_sections(log)
        self.assertEqual(s["fpcheck"], (0, "{\"fpcheck\": 1}\n"))
        self.assertEqual(s["bench"], (3, "x\ny\n"))


class Compare(unittest.TestCase):
    def fp(self, **patterns):
        return {"patterns_total": 3, "patterns": patterns, "mix_values": "m", "mix_flags": "f",
                "mix_runs": 1, "runs": 1, "seconds": 1, "mix_seconds": 1, "sigill": []}

    def run_compare(self, native, off, on, *extra):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            for name, data in (("native", native), ("off", off), ("on", on)):
                (d / name).mkdir()
                (d / name / "fpcheck.json").write_text(json.dumps(data))
            argv = sys.argv
            sys.argv = ["compare.py", "--native", str(d / "native"), "--off", str(d / "off"),
                        "--on", str(d / "on"), *extra]
            try:
                return compare.main()
            finally:
                sys.argv = argv

    def test_equal_passes(self):
        a = self.fp(A=["1", "2"], B=["3", "4"])
        self.assertEqual(self.run_compare(a, a, a), 0)

    def test_value_difference_with_host_vfp_fails(self):
        a = self.fp(A=["1", "2"])
        b = self.fp(A=["9", "2"])
        self.assertEqual(self.run_compare(a, a, b), 1)

    def test_helper_difference_is_only_reported(self):
        a = self.fp(A=["1", "2"])
        b = self.fp(A=["9", "2"])
        self.assertEqual(self.run_compare(a, b, a), 0)

    def test_flag_difference_fails_only_when_strict(self):
        a = self.fp(A=["1", "2"])
        b = self.fp(A=["1", "7"])
        self.assertEqual(self.run_compare(a, a, b), 0)
        self.assertEqual(self.run_compare(a, a, b, "--strict-flags"), 1)

    def test_mixed_sequence_difference_fails(self):
        a = self.fp(A=["1", "2"])
        b = dict(a, mix_values="other")
        self.assertEqual(self.run_compare(a, a, b), 1)

    def test_bench_table_ratio(self):
        rows = {"native": {"results": [{"name": "fp", "unit": "u", "value": 100.0, "ok": 1}]},
                "vfp-off": {"results": [{"name": "fp", "unit": "u", "value": 10.0, "ok": 1}]},
                "vfp-on": {"results": [{"name": "fp", "unit": "u", "value": 40.0, "ok": 1}]}}
        table = "\n".join(compare.bench_table(rows))
        self.assertIn("| fp | u | 100.00 | 10.00 | 40.00 | 4.00x |", table)


if __name__ == "__main__":
    unittest.main()
