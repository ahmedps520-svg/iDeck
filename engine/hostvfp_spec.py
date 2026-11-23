#!/usr/bin/env python3
"""Instruction patterns for iDeck's QEMU host-VFP pass-through.

One table, two consumers:

  --table FILE   the C table included by QEMU's A64 translator
                 (target/arm/tcg/host-vfp-pats.c.inc in engine/qemu/*.patch)
  --cases FILE   test encodings for bench/fpcheck.c, which runs every
                 pattern on real hardware and under QEMU and compares

A pattern is a 32-character bit string, bit 31 first (spaces ignored):

  0 1    fixed bits
  .      any value
  d n m a   a V register in the Rd (4:0), Rn (9:5), Rm (20:16) or
            Ra (14:10) field
  D N    a general register in the Rd or Rn field

Only instructions that exist in every ARMv8.0 CPU are listed, except
where `feat` names the CPU feature both guest and host must have.
Half-precision forms are left to QEMU's helpers.
"""
from __future__ import annotations

import argparse
import random
from dataclasses import dataclass

# Kinds: must match the enum in QEMU's include/tcg/tcg-host-vfp.h.
VEC, FLAGS_OUT, FLAGS_INOUT, GPR_OUT, GPR_OUT_FLAGS, GPR_IN = range(6)
KIND_NAMES = ["VEC", "FLAGS_OUT", "FLAGS_INOUT", "GPR_OUT", "GPR_OUT_FLAGS", "GPR_IN"]

# Flag bits: must match target/arm/tcg/host-vfp-a64.c.inc.
HV_RD = 1 << 3      # Rd names a V register that is written
HV_RD_IN = 1 << 4   # ... and its old value is an input
HV_RN = 1 << 5
HV_RM = 1 << 6
HV_RA = 1 << 7
HV_SCALAR = 1 << 8  # scalar result: FPCR.NEP merges the old Rd
HV_VEC_SD = 1 << 9  # Q=0 with sz=1 is unallocated
HV_Q1 = 1 << 10     # only allocated with Q=1
HV_NO_AH = 1 << 11  # result depends on FEAT_RPRES when FPCR.AH=1
HV_TBL = 1 << 12    # table registers Rn .. Rn+len
HV_FEAT_SHIFT = 16

FEATS = ["NONE", "JSCVT", "AES", "SHA1", "SHA256", "PMULL"]


@dataclass(frozen=True)
class Pattern:
    name: str
    bits: str
    kind: int = VEC
    rd_in: bool = False
    scalar: bool = False
    vec_sd: bool = False
    q1: bool = False
    no_ah: bool = False
    tbl: bool = False
    feat: str = "NONE"

    @property
    def clean(self) -> str:
        b = self.bits.replace(" ", "")
        if len(b) != 32:
            raise ValueError(f"{self.name}: {len(b)} bits")
        return b

    @property
    def mask(self) -> int:
        return int("".join("1" if c in "01" else "0" for c in self.clean), 2)

    @property
    def value(self) -> int:
        return int("".join(c if c in "01" else "0" for c in self.clean), 2)

    def field(self, letter: str) -> bool:
        return letter in self.clean

    @property
    def flags(self) -> int:
        f = self.kind
        if self.field("d"):
            f |= HV_RD
        if self.rd_in:
            f |= HV_RD_IN
        if self.field("n"):
            f |= HV_RN
        if self.field("m"):
            f |= HV_RM
        if self.field("a"):
            f |= HV_RA
        if self.scalar:
            f |= HV_SCALAR
        if self.vec_sd:
            f |= HV_VEC_SD
        if self.q1:
            f |= HV_Q1
        if self.no_ah:
            f |= HV_NO_AH
        if self.tbl:
            f |= HV_TBL
        return f | (FEATS.index(self.feat) << HV_FEAT_SHIFT)

    def check(self) -> None:
        b = self.clean
        pos = {"d": (27, 32), "D": (27, 32), "n": (22, 27), "N": (22, 27),
               "m": (11, 16), "a": (17, 22)}
        for i, c in enumerate(b):
            if c in "01.":
                continue
            lo, hi = pos[c]
            if not lo <= i < hi:
                raise ValueError(f"{self.name}: field {c} at string index {i}")
        for c, (lo, hi) in pos.items():
            if c in b and b[lo:hi] != c * 5:
                raise ValueError(f"{self.name}: field {c} is not 5 bits wide")
        if self.kind in (GPR_OUT, GPR_OUT_FLAGS) and "D" not in b:
            raise ValueError(f"{self.name}: GPR_OUT without D")
        if self.kind == GPR_IN and "N" not in b:
            raise ValueError(f"{self.name}: GPR_IN without N")
        if self.rd_in and "d" not in b:
            raise ValueError(f"{self.name}: rd_in without d")
        if (b[4:8] not in ("111.", "1110", "1111")):
            raise ValueError(f"{self.name}: not in the SIMD&FP class")

    def matches(self, insn: int) -> bool:
        return (insn & self.mask) == self.value

    def allocated(self, insn: int) -> bool:
        """The extra checks the translator makes after the mask matches."""
        q = (insn >> 30) & 1
        sz = (insn >> 22) & 1
        if self.vec_sd and sz and not q:
            return False
        if self.q1 and not q:
            return False
        return True


def _scalar2(name: str, op: str) -> Pattern:
    return Pattern(name, f"00011110 0.1 mmmmm {op} 10 nnnnn ddddd", scalar=True)


def _scalar1(name: str, op: str, **kw) -> Pattern:
    return Pattern(name, f"00011110 0.1 {op} 10000 nnnnn ddddd", scalar=True, **kw)


def _s3same(name: str, u: str, hi: str, op: str) -> Pattern:
    return Pattern(name, f"01{u}11110 {hi}.1 mmmmm {op} 1 nnnnn ddddd", scalar=True)


def _s2misc(name: str, u: str, hi: str, r: str, op: str, **kw) -> Pattern:
    return Pattern(name, f"01{u}11110 {hi}.1 {r} {op} 0 nnnnn ddddd", scalar=True, **kw)


def _v3same(name: str, u: str, hi: str, op: str, **kw) -> Pattern:
    return Pattern(name, f"0.{u}01110 {hi}.1 mmmmm {op} 1 nnnnn ddddd", vec_sd=True, **kw)


def _v2misc(name: str, u: str, hi: str, r: str, op: str, **kw) -> Pattern:
    kw.setdefault("vec_sd", True)
    return Pattern(name, f"0.{u}01110 {hi}.1 {r} {op} 0 nnnnn ddddd", **kw)


def _build() -> list[Pattern]:
    p: list[Pattern] = []

    # --- Scalar floating-point data processing --------------------------
    for name, op in [("FMUL", "0000"), ("FDIV", "0001"), ("FADD", "0010"),
                     ("FSUB", "0011"), ("FMAX", "0100"), ("FMIN", "0101"),
                     ("FMAXNM", "0110"), ("FMINNM", "0111"), ("FNMUL", "1000")]:
        p.append(_scalar2(name + "_s", op))
    for name, op in [("FSQRT", "000011"), ("FRINTN", "001000"), ("FRINTP", "001001"),
                     ("FRINTM", "001010"), ("FRINTZ", "001011"), ("FRINTA", "001100"),
                     ("FRINTX", "001110"), ("FRINTI", "001111")]:
        p.append(_scalar1(name + "_s", op))
    p.append(Pattern("FCVT_s_ds", "00011110 001 000101 10000 nnnnn ddddd", scalar=True))
    p.append(Pattern("FCVT_s_sd", "00011110 011 000100 10000 nnnnn ddddd", scalar=True))
    # FMADD, FMSUB, FNMADD, FNMSUB
    p.append(Pattern("FMADD_all", "00011111 0.. mmmmm . aaaaa nnnnn ddddd", scalar=True))
    # FCMP / FCMPE with a register, with zero; FCCMP / FCCMPE
    p.append(Pattern("FCMP", "00011110 0.1 mmmmm 001000 nnnnn .0000", kind=FLAGS_OUT))
    p.append(Pattern("FCMP_z", "00011110 0.1 00000 001000 nnnnn .1000", kind=FLAGS_OUT))
    p.append(Pattern("FCCMP", "00011110 0.1 mmmmm .... 01 nnnnn .....", kind=FLAGS_INOUT))

    # --- AdvSIMD scalar ---------------------------------------------------
    p += [
        _s3same("FMULX_s", "0", "0", "11011"),
        _s3same("FCMEQ_s", "0", "0", "11100"),
        _s3same("FCMGE_s", "1", "0", "11100"),
        _s3same("FCMGT_s", "1", "1", "11100"),
        _s3same("FACGE_s", "1", "0", "11101"),
        _s3same("FACGT_s", "1", "1", "11101"),
        _s3same("FABD_s", "1", "1", "11010"),
        _s3same("FRECPS_s", "0", "0", "11111"),
        _s3same("FRSQRTS_s", "0", "1", "11111"),
    ]
    for name, hi, op in [("FADDP", "0", "1101"), ("FMAXP", "0", "1111"),
                         ("FMINP", "1", "1111"), ("FMAXNMP", "0", "1100"),
                         ("FMINNMP", "1", "1100")]:
        p.append(Pattern(name + "_s", f"01111110 {hi}.11 0000 {op} 10 nnnnn ddddd",
                         scalar=True))
    p += [
        _s2misc("FCMGT0_s", "0", "1", "00000", "11001"),
        _s2misc("FCMGE0_s", "1", "1", "00000", "11001"),
        _s2misc("FCMEQ0_s", "0", "1", "00000", "11011"),
        _s2misc("FCMLE0_s", "1", "1", "00000", "11011"),
        _s2misc("FCMLT0_s", "0", "1", "00000", "11101"),
        _s2misc("FRECPE_s", "0", "1", "00001", "11011", no_ah=True),
        _s2misc("FRECPX_s", "0", "1", "00001", "11111"),
        _s2misc("FRSQRTE_s", "1", "1", "00001", "11011", no_ah=True),
        _s2misc("SCVTF_f", "0", "0", "00001", "11011"),
        _s2misc("UCVTF_f", "1", "0", "00001", "11011"),
        _s2misc("FCVTNS_f", "0", "0", "00001", "10101"),
        _s2misc("FCVTNU_f", "1", "0", "00001", "10101"),
        _s2misc("FCVTPS_f", "0", "1", "00001", "10101"),
        _s2misc("FCVTPU_f", "1", "1", "00001", "10101"),
        _s2misc("FCVTMS_f", "0", "0", "00001", "10111"),
        _s2misc("FCVTMU_f", "1", "0", "00001", "10111"),
        _s2misc("FCVTZS_f", "0", "1", "00001", "10111"),
        _s2misc("FCVTZU_f", "1", "1", "00001", "10111"),
        _s2misc("FCVTAS_f", "0", "0", "00001", "11001"),
        _s2misc("FCVTAU_f", "1", "0", "00001", "11001"),
    ]
    p.append(Pattern("FCVTXN_s", "01111110 011 00001 01101 0 nnnnn ddddd", scalar=True))
    for name, u, op, rd_in in [("FMUL", "0", "1001", False), ("FMLA", "0", "0001", True),
                               ("FMLS", "0", "0101", True), ("FMULX", "1", "1001", False)]:
        p.append(Pattern(name + "_si_s", f"01{u}11111 10 . mmmmm {op} . 0 nnnnn ddddd",
                         scalar=True, rd_in=rd_in))
        p.append(Pattern(name + "_si_d", f"01{u}11111 11 0 mmmmm {op} . 0 nnnnn ddddd",
                         scalar=True, rd_in=rd_in))
    for name, u, op in [("SCVTF", "0", "111001"), ("UCVTF", "1", "111001"),
                        ("FCVTZS", "0", "111111"), ("FCVTZU", "1", "111111")]:
        p.append(Pattern(name + "_fixed_s", f"01{u}11111 0 01..... {op} nnnnn ddddd",
                         scalar=True))
        p.append(Pattern(name + "_fixed_d", f"01{u}11111 0 1...... {op} nnnnn ddddd",
                         scalar=True))

    # --- AdvSIMD vector -----------------------------------------------------
    p += [
        _v3same("FMAXNM_v", "0", "0", "11000"),
        _v3same("FMLA_v", "0", "0", "11001", rd_in=True),
        _v3same("FADD_v", "0", "0", "11010"),
        _v3same("FMULX_v", "0", "0", "11011"),
        _v3same("FCMEQ_v", "0", "0", "11100"),
        _v3same("FMAX_v", "0", "0", "11110"),
        _v3same("FRECPS_v", "0", "0", "11111"),
        _v3same("FMINNM_v", "0", "1", "11000"),
        _v3same("FMLS_v", "0", "1", "11001", rd_in=True),
        _v3same("FSUB_v", "0", "1", "11010"),
        _v3same("FMIN_v", "0", "1", "11110"),
        _v3same("FRSQRTS_v", "0", "1", "11111"),
        _v3same("FMAXNMP_v", "1", "0", "11000"),
        _v3same("FADDP_v", "1", "0", "11010"),
        _v3same("FMUL_v", "1", "0", "11011"),
        _v3same("FCMGE_v", "1", "0", "11100"),
        _v3same("FACGE_v", "1", "0", "11101"),
        _v3same("FMAXP_v", "1", "0", "11110"),
        _v3same("FDIV_v", "1", "0", "11111"),
        _v3same("FMINNMP_v", "1", "1", "11000"),
        _v3same("FABD_v", "1", "1", "11010"),
        _v3same("FCMGT_v", "1", "1", "11100"),
        _v3same("FACGT_v", "1", "1", "11101"),
        _v3same("FMINP_v", "1", "1", "11110"),
    ]
    for name, u, op, rd_in in [("FMUL", "0", "1001", False), ("FMLA", "0", "0001", True),
                               ("FMLS", "0", "0101", True), ("FMULX", "1", "1001", False)]:
        p.append(Pattern(name + "_vi_s", f"0.{u}01111 10 . mmmmm {op} . 0 nnnnn ddddd",
                         rd_in=rd_in))
        p.append(Pattern(name + "_vi_d", f"0.{u}01111 11 0 mmmmm {op} . 0 nnnnn ddddd",
                         rd_in=rd_in, q1=True))
    p += [
        _v2misc("FSQRT_v", "1", "1", "00001", "11111"),
        _v2misc("FRINTN_v", "0", "0", "00001", "10001"),
        _v2misc("FRINTM_v", "0", "0", "00001", "10011"),
        _v2misc("FRINTP_v", "0", "1", "00001", "10001"),
        _v2misc("FRINTZ_v", "0", "1", "00001", "10011"),
        _v2misc("FRINTA_v", "1", "0", "00001", "10001"),
        _v2misc("FRINTX_v", "1", "0", "00001", "10011"),
        _v2misc("FRINTI_v", "1", "1", "00001", "10011"),
        _v2misc("SCVTF_vi", "0", "0", "00001", "11011"),
        _v2misc("UCVTF_vi", "1", "0", "00001", "11011"),
        _v2misc("FCVTNS_vi", "0", "0", "00001", "10101"),
        _v2misc("FCVTNU_vi", "1", "0", "00001", "10101"),
        _v2misc("FCVTPS_vi", "0", "1", "00001", "10101"),
        _v2misc("FCVTPU_vi", "1", "1", "00001", "10101"),
        _v2misc("FCVTMS_vi", "0", "0", "00001", "10111"),
        _v2misc("FCVTMU_vi", "1", "0", "00001", "10111"),
        _v2misc("FCVTZS_vi", "0", "1", "00001", "10111"),
        _v2misc("FCVTZU_vi", "1", "1", "00001", "10111"),
        _v2misc("FCVTAS_vi", "0", "0", "00001", "11001"),
        _v2misc("FCVTAU_vi", "1", "0", "00001", "11001"),
        _v2misc("FCMGT0_v", "0", "1", "00000", "11001"),
        _v2misc("FCMGE0_v", "1", "1", "00000", "11001"),
        _v2misc("FCMEQ0_v", "0", "1", "00000", "11011"),
        _v2misc("FCMLE0_v", "1", "1", "00000", "11011"),
        _v2misc("FCMLT0_v", "0", "1", "00000", "11101"),
        _v2misc("FRECPE_v", "0", "1", "00001", "11011", no_ah=True),
        _v2misc("FRSQRTE_v", "1", "1", "00001", "11011", no_ah=True),
        # Narrowing and lengthening between precisions; sz selects
        # half<->single or single<->double, both allocated for either Q.
        # FCVTN2/FCVTXN2 (Q=1) keep the low half of Rd.
        _v2misc("FCVTN_v", "0", "0", "00001", "01101", vec_sd=False, rd_in=True),
        _v2misc("FCVTL_v", "0", "0", "00001", "01111", vec_sd=False),
    ]
    p.append(Pattern("FCVTXN_v", "0.101110 011 00001 01101 0 nnnnn ddddd", rd_in=True))
    for name, hi, op in [("FMAXNMV", "0", "01100"), ("FMINNMV", "1", "01100"),
                         ("FMAXV", "0", "01111"), ("FMINV", "1", "01111")]:
        p.append(Pattern(name + "_s", f"01101110 {hi}0 11000 {op} 10 nnnnn ddddd",
                         scalar=True))
    for name, u, op in [("SCVTF", "0", "111001"), ("UCVTF", "1", "111001"),
                        ("FCVTZS", "0", "111111"), ("FCVTZU", "1", "111111")]:
        p.append(Pattern(name + "_vf_s", f"0.{u}011110 01..... {op} nnnnn ddddd"))
        p.append(Pattern(name + "_vf_d", f"0.{u}011110 1...... {op} nnnnn ddddd", q1=True))

    # --- Conversions with a general register ------------------------------
    for name, op in [("SCVTF", "100010"), ("UCVTF", "100011")]:
        p.append(Pattern(name + "_g", f". 0011110 0. {op} 000000 NNNNN ddddd",
                         kind=GPR_IN, scalar=True))
    for name, op in [("FCVTNS", "100000"), ("FCVTNU", "100001"), ("FCVTPS", "101000"),
                     ("FCVTPU", "101001"), ("FCVTMS", "110000"), ("FCVTMU", "110001"),
                     ("FCVTZS", "111000"), ("FCVTZU", "111001"), ("FCVTAS", "100100"),
                     ("FCVTAU", "100101")]:
        p.append(Pattern(name + "_g", f". 0011110 0. {op} 000000 nnnnn DDDDD", kind=GPR_OUT))
    # Fixed point: with a 32-bit general register the scale field is 1xxxxx.
    for name, op in [("SCVTF", "000010"), ("UCVTF", "000011")]:
        p.append(Pattern(name + "_gf32", f"0 0011110 0. {op} 1..... NNNNN ddddd",
                         kind=GPR_IN, scalar=True))
        p.append(Pattern(name + "_gf64", f"1 0011110 0. {op} ...... NNNNN ddddd",
                         kind=GPR_IN, scalar=True))
    for name, op in [("FCVTZS", "011000"), ("FCVTZU", "011001")]:
        p.append(Pattern(name + "_gf32", f"0 0011110 0. {op} 1..... nnnnn DDDDD",
                         kind=GPR_OUT))
        p.append(Pattern(name + "_gf64", f"1 0011110 0. {op} ...... nnnnn DDDDD",
                         kind=GPR_OUT))
    p.append(Pattern("FJCVTZS", "0 0011110 01 111110 000000 nnnnn DDDDD",
                     kind=GPR_OUT_FLAGS, feat="JSCVT"))

    # --- Cryptography and table lookup -------------------------------------
    p.append(Pattern("AESE", "01001110 00 10100 00100 10 nnnnn ddddd", rd_in=True, feat="AES"))
    p.append(Pattern("AESD", "01001110 00 10100 00101 10 nnnnn ddddd", rd_in=True, feat="AES"))
    p.append(Pattern("AESMC", "01001110 00 10100 00110 10 nnnnn ddddd", feat="AES"))
    p.append(Pattern("AESIMC", "01001110 00 10100 00111 10 nnnnn ddddd", feat="AES"))
    for name, op, feat in [("SHA1C", "000", "SHA1"), ("SHA1P", "001", "SHA1"),
                           ("SHA1M", "010", "SHA1"), ("SHA1SU0", "011", "SHA1"),
                           ("SHA256H", "100", "SHA256"), ("SHA256H2", "101", "SHA256"),
                           ("SHA256SU1", "110", "SHA256")]:
        p.append(Pattern(name, f"01011110 000 mmmmm 0 {op} 00 nnnnn ddddd",
                         rd_in=True, feat=feat))
    p.append(Pattern("SHA1H", "01011110 0010 1000 0000 10 nnnnn ddddd", feat="SHA1"))
    p.append(Pattern("SHA1SU1", "01011110 0010 1000 0001 10 nnnnn ddddd",
                     rd_in=True, feat="SHA1"))
    p.append(Pattern("SHA256SU0", "01011110 0010 1000 0010 10 nnnnn ddddd",
                     rd_in=True, feat="SHA256"))
    p.append(Pattern("PMULL_p64", "0.001110 111 mmmmm 11100 0 nnnnn ddddd", feat="PMULL"))
    p.append(Pattern("PMULL_p8", "0.001110 001 mmmmm 11100 0 nnnnn ddddd"))
    # TBL/TBX: bits 14:13 = number of table registers - 1, bit 12 = TBX
    # (which keeps the bytes of Rd whose index is out of range).
    p.append(Pattern("TBL_TBX", "0.001110 000 mmmmm 0 ... 00 nnnnn ddddd", rd_in=True, tbl=True))
    return p


PATTERNS = _build()


def validate() -> None:
    names = set()
    for pat in PATTERNS:
        pat.check()
        if pat.name in names:
            raise ValueError(f"duplicate name {pat.name}")
        names.add(pat.name)
    # No encoding may match two patterns: sample each pattern and look
    # for a second match.
    rng = random.Random(1)
    for pat in PATTERNS:
        for _ in range(200):
            insn = pat.value | (rng.getrandbits(32) & ~pat.mask)
            hits = [q.name for q in PATTERNS if q.matches(insn)]
            if hits != [pat.name]:
                raise ValueError(f"{insn:#010x} matches {hits}")


def lookup(insn: int) -> Pattern | None:
    for pat in PATTERNS:
        if pat.matches(insn):
            return pat if pat.allocated(insn) else None
    return None


def table_c() -> str:
    out = [
        "/*",
        " * Generated by iDeck engine/hostvfp_spec.py --table; do not edit.",
        " * { mask, value, flags } for instructions that run on the host as is.",
        " */",
    ]
    for pat in PATTERNS:
        out.append(f"    {{ 0x{pat.mask:08x}, 0x{pat.value:08x}, 0x{pat.flags:06x} }},"
                   f" /* {pat.name} */")
    return "\n".join(out) + "\n"


# Register choices for test encodings: (Rd, Rn, Rm, Ra).  They cover
# plain use, every aliasing shape, and guest registers that share numbers
# with the host slot registers (V25-V30) and V31.
REG_SETS = [
    (0, 1, 2, 3),
    (4, 4, 5, 6),      # Rd = Rn
    (7, 8, 7, 9),      # Rd = Rm
    (10, 11, 12, 10),  # Rd = Ra
    (13, 14, 14, 15),  # Rn = Rm
    (16, 16, 16, 16),  # all the same
    (25, 26, 27, 28),
    (30, 29, 31, 30),
    (31, 25, 26, 27),
    (27, 31, 30, 29),
]
TEST_GPR = 9  # general register used by the GPR kinds in test encodings


def cases(seed: int = 20261123, per_regset: int = 2) -> list[tuple[int, int]]:
    """(instruction, pattern index) pairs for fpcheck."""
    rng = random.Random(seed)
    out: list[tuple[int, int]] = []
    seen: set[int] = set()
    for idx, pat in enumerate(PATTERNS):
        b = pat.clean
        for rd, rn, rm, ra in REG_SETS:
            for _ in range(per_regset):
                for _attempt in range(64):
                    insn = pat.value | (rng.getrandbits(32) & ~pat.mask)

                    def put(v: int, lsb: int) -> None:
                        nonlocal insn
                        insn = (insn & ~(0x1f << lsb)) | (v << lsb)

                    if "d" in b:
                        put(rd, 0)
                    if "D" in b:
                        put(TEST_GPR, 0)
                    if "n" in b:
                        put(rn, 5)
                    if "N" in b:
                        put(TEST_GPR, 5)
                    if "m" in b:
                        put(rm, 16)
                    if "a" in b:
                        put(ra, 10)
                    if pat.allocated(insn) and insn not in seen:
                        seen.add(insn)
                        out.append((insn, idx))
                        break
    return out


def cases_c() -> str:
    cs = cases()
    out = [
        "/*",
        " * Generated by iDeck engine/hostvfp_spec.py --cases; do not edit.",
        " * Test encodings for every host-VFP pattern (bench/fpcheck.c).",
        " */",
        f"#define FPCHECK_NPATTERNS {len(PATTERNS)}",
        f"#define FPCHECK_NCASES {len(cs)}",
        f"#define FPCHECK_GPR {TEST_GPR}",
        "static const char *const fpcheck_names[FPCHECK_NPATTERNS] = {",
    ]
    for pat in PATTERNS:
        out.append(f'    "{pat.name}",')
    out.append("};")
    out.append("/* kind of each pattern (tcg-host-vfp.h order) */")
    out.append("static const unsigned char fpcheck_kinds[FPCHECK_NPATTERNS] = {")
    out.append("    " + ", ".join(str(pat.kind) for pat in PATTERNS))
    out.append("};")
    out.append("/* CPU feature each pattern needs (index into fpcheck_feats) */")
    out.append("static const unsigned char fpcheck_feat[FPCHECK_NPATTERNS] = {")
    out.append("    " + ", ".join(str(FEATS.index(pat.feat)) for pat in PATTERNS))
    out.append("};")
    out.append("static const char *const fpcheck_feats[] = {")
    out.append("    " + ", ".join(f'"{f}"' for f in FEATS))
    out.append("};")
    out.append("static const struct { unsigned insn; unsigned short pat; }"
               " fpcheck_cases[FPCHECK_NCASES] = {")
    for insn, idx in cs:
        out.append(f"    {{ 0x{insn:08x}, {idx} }},")
    out.append("};")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--table", help="write the QEMU pattern table")
    ap.add_argument("--cases", help="write the fpcheck test encodings")
    args = ap.parse_args()
    validate()
    if args.table:
        with open(args.table, "w", encoding="utf-8", newline="\n") as f:
            f.write(table_c())
    if args.cases:
        with open(args.cases, "w", encoding="utf-8", newline="\n") as f:
            f.write(cases_c())
    print(f"{len(PATTERNS)} patterns, {len(cases())} test encodings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
