"""Tests for the boot-test helpers in tools/ideck_host.py."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ideck_host as h  # noqa: E402

# `info jit` as QEMU 8.2 prints it (accel/tcg dump_exec_info): note the
# single space before the value on the longer keys.
JIT_TEXT = """Translation buffer state:
gen code size       301989888/402653184
TB count            812345
TB avg target size  17 max=1024 bytes
TB avg host size    210 bytes (expansion ratio: 12.3)
cross page TB count 9876 (1%)
direct jump count   500000 (61%) (2 jumps=300000 36%)
TB hash buckets     65536/65536 (100.00% head buckets used)
TB hash occupancy   45.10% avg chain occ. Histogram: [0,10)%|_ |[90,100]%
TB hash avg chain   1.234 buckets. Histogram: 1|_|3

Statistics:
TB flush count      3
TB invalidate count 120456
TLB full flushes    4567
TLB partial flushes 89012
TLB elided flushes  345
"""


class JitInfoTests(unittest.TestCase):
    def test_parses_qemu_info_jit(self):
        s = h.parse_jit_info(JIT_TEXT)
        self.assertEqual(s["gen_code_bytes"], 301989888)
        self.assertEqual(s["code_buffer_bytes"], 402653184)
        self.assertEqual(s["tb_count"], 812345)
        self.assertEqual(s["tb_flush"], 3)
        self.assertEqual(s["tb_invalidate"], 120456)
        self.assertEqual(s["tlb_full_flushes"], 4567)
        self.assertEqual(s["tlb_partial_flushes"], 89012)
        self.assertNotIn("tb_avg_target_size", s)

    def test_empty_or_unknown_text(self):
        self.assertEqual(h.parse_jit_info(""), {})
        self.assertEqual(h.parse_jit_info("TB flush count  n/a\n"), {})


class TopSummaryTests(unittest.TestCase):
    def test_webhelper_affinity_and_groups(self):
        top = {
            "cpu_percent": 61.2, "online_cpus": "0-3",
            "processes": [
                {"pid": 10, "comm": "steamwebhelper", "cpu": 80.0, "cpus": "2-3"},
                {"pid": 11, "comm": "steamwebhelper", "cpu": 40.0, "cpus": "2-3"},
                {"pid": 12, "comm": "steam", "cpu": 20.0, "cpus": "0-3"},
            ],
            "by_command": [{"comm": "steamwebhelper", "cpu": 120.0, "processes": 7}] * 8,
        }
        s = h.top_summary(top)
        self.assertEqual(s["webhelper_cpus_allowed"], ["2-3"])
        self.assertEqual(s["webhelper_processes_listed"], 2)
        self.assertEqual(len(s["by_command"]), 6)
        self.assertEqual(s["online_cpus"], "0-3")

    def test_missing_fields(self):
        s = h.top_summary({})
        self.assertEqual(s["webhelper_cpus_allowed"], [])
        self.assertEqual(s["by_command"], [])


if __name__ == "__main__":
    unittest.main()
