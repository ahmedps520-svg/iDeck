# CPU engine

## What runs the guest

**QEMU 10.0.12 (utmapp fork), TCG**, multi-threaded (one host thread per vCPU),
started in-process. QEMU is not reimplemented. The prompt said not to write a new
emulator where an existing one achieves the result, and on iPadOS no hypervisor is
available, so a binary translator is the only option.

From build 36 the sideload edition embeds that QEMU rebuilt with iDeck's engine
patch (`engine/qemu`), which runs the guest's floating-point instructions on the
iPad's CPU: see [Native floating point](#native-floating-point-build-36).

| Requirement | Where it is met |
|---|---|
| ARM64 guest execution, registers, CPU state, exceptions, interrupts (GICv3), timers | QEMU `virt` machine, TCG |
| Guest memory management, virtual address translation | QEMU softmmu (TLB), guest RAM as anonymous memory or a file (`memory-backend-file`, experimental) |
| JIT compilation where permitted | TCG with `split-wx=on` and the TXM debugger protocol ([DISTRIBUTION](DISTRIBUTION.md)) |
| Translation caching | TCG translation-block cache, sized by the core (`tb-size`: 256/384/512 MiB) so it cannot grow to QEMU's 1 GiB default under jetsam |
| Thread management | MTTCG (`thread=multi`), vCPUs per performance profile (2/4/6) |
| System calls | Guest Linux kernel (full system emulation) |
| Interpreter fallback | TCI build of the same QEMU (TestFlight edition) |
| Profiling | `ideck-bench` in the guest, guest CPU metrics from the agent, QEMU log |

### Guest CPU model

Default **`neoverse-n1`** (ARMv8.2: LSE atomics, LRCPC, dot product, FP16):

- The ARM64 Steam client reportedly needs ARMv8.1 LSE in recent builds, so UTM's default `cortex-a72` is unsuitable. The core warns if it is selected.
- FEX selects its v8.2 build on these features.
- It avoids pointer authentication and SVE, which are expensive in TCG and unnecessary here. `max` is offered with `pauth=off,sve=off,sme=off`.
- Research found a reported QEMU issue: TCG may emit wrong CSSC min/max encodings on hosts that have FEAT_CSSC (Apple M5), causing SIGILL with `-cpu max`. This is unverified. If it reproduces on device, the fix belongs in the TCG aarch64 backend (disable CSSC use) as a patch to the QEMU sysroot build.

## Native floating point (build 36)

**The problem.** TCG turns every guest floating-point instruction into a call to a
software routine (softfloat). In CI the guest ran integer code at about a third of
the runner's native speed, but floating point at 3% (`fp_single`: 228 against
8,090 MFLOP/s). Games, Chromium's drawing and JavaScript numbers are floating
point, and x86 games add more: FEX turns their SSE code into ARM floating point.

**What the patch does.** `engine/qemu/0001-host-vfp.patch` applies on top of UTM's
QEMU 10.0.12 and is switched on with `-cpu …,x-host-vfp=on`. Guest and host are
both ARM64, so a guest floating-point instruction can run on the host as it is:
- The translator recognises 189 instruction patterns: scalar and vector arithmetic,
  compares, conversions, rounding, square root, register moves, AES/SHA/PMULL and
  table lookup. `engine/hostvfp_spec.py` is the list; it generates the translator's
  table and the test encodings.
- For each one it emits the same instruction with its registers renumbered to six
  host registers (V8–V13), after loading the guest registers it needs from QEMU's
  CPU state, and stores the result back.
- Within a translation block it tracks which guest register each of the six holds,
  so a chain of scalar operations passes values in registers instead of through
  memory. V8–V13 are callee-saved and never used by TCG; any other instruction may
  call a helper, after which only their low halves are relied on.
- While guest code runs, the host FPCR holds the guest's rounding mode,
  flush-to-zero, default-NaN and alternative-half-precision bits, and the host
  FPSR collects the guest's exception flags.
- Half precision, integer SIMD (TCG already emits host SIMD for it), SVE and all
  memory access stay as QEMU does them.

**Limits chosen for safety.**
- FEAT_AFP is hidden from the guest. It changes what many of these instructions
  do, and the CI host does not have it, so it could not be tested. FEX uses its
  code paths for CPUs without it.
- Every result is stored to the CPU state right away, so the state is exact at
  each instruction boundary whatever happens next.
- The interpreter (TestFlight) edition keeps UTM's unpatched QEMU.
- **Settings › Advanced › Native floating point** turns it off. iDeck turns it off by
  itself after two starts in a row in which Linux never came up.

**How it is checked.** `bench/fpcheck.c` is one static binary:
- It runs 5,694 encodings of the 189 patterns with NaNs, infinities, denormals,
  limits and random operands under eight FPCR settings: 1,093,248 runs.
- It runs 30,000 random sequences of up to 32 instructions that mix listed
  instructions with 104 others (every floating-point load and store form,
  structure loads, helper-based operations): 90,000 runs.
- Each run hashes all 32 vector registers, NZCV, a general register and the FPSR
  flags.
- `engine.yml` runs it on the runner's CPU (Neoverse N2, real hardware), in a
  guest with QEMU's helpers and in a guest with native floating point, on the
  same QEMU source the iPad build uses, and fails on any difference.
- The runtime image (0.1.13+) carries the binary with the digests from the build
  host. The agent's `fpcheck.run` compares inside Linux. The app runs it once per
  runtime and build, logs `engine: floating-point check, …` and shows the result
  under Settings › Advanced.

**Results in CI** (`engine.yml` run 45245742398; ARM64 runner, guests with 4
vCPUs; the same binaries in every column):

| | Runner's CPU | Guest, QEMU helpers | Guest, native FP | Gain |
|---|---:|---:|---:|---:|
| fpcheck, 189 patterns | reference | all equal | **all equal** | |
| fpcheck, mixed sequences | reference | equal | **equal** | |
| fp_scalar (8-body simulation, doubles) | 261.8 Mpairs/s | 14.8 | 35.7 | 2.4× |
| fp_convert (fractal: compares, conversions) | 349.0 Miter/s | 35.7 | 115.1 | 3.2× |
| fp_vector (single-precision NEON) | 4,966 Melem/s | 59.1 | 429.3 | 7.3× |
| fp_single (matrix multiply, double NEON) | 8,090 MFLOP/s | 228.4 | 586.1 | 2.6× |
| int_single | 8,345 Mops/s | 2,589 | 2,453 | unchanged |
| syscall | 213 ns | 2,272 | 2,265 | unchanged |

- Register results and FPSR flags were identical to hardware for every pattern
  and every mixed sequence, with helpers and with native floating point.
- The first run (45240386488) had a stray inexact flag on five patterns: GLib
  computes `nnodes * 1.333` when it resizes TCG's constant table, on the vCPU
  thread, while the host FPSR holds the guest's flags. The translator now saves
  and restores the host FPSR around translation (run 45243645133: no difference).
- Before the slot tracking, scalar code gained 1.6× (fp_scalar) and 2.6×
  (fp_convert); loading every operand from memory was the limit.

**What is still slow.** Native floating point is still 7–14 times slower than the
runner's CPU in these loops. Every result is stored, every guest memory access
goes through the soft MMU, and 128-bit values are reloaded after any other
instruction. Integer code, memory access and system calls are unchanged.

**Not known yet.** Nothing here has run on an iPad. How much of a game's or of
Steam's time is floating point decides what the user sees; CI measures loops.

**Building it.** `ios/scripts/build_qemu.sh` rebuilds only QEMU (aarch64-softmmu)
against UTM's prebuilt sysroot. It runs UTM's own build script up to the point
where that would start building, so the compiler, SDK, flags and UTM's QEMU
patch are the same, applies `engine/qemu/*.patch`, and checks that the result
links the same libraries as UTM's QEMU. The patch changes GPL code and is
GPL-2.0-or-later like the files it touches ([THIRD_PARTY](../THIRD_PARTY.md)).

## Two layers of translation for x86

x86-64 games run in FEX inside the guest. FEX translates x86 to ARM64 code, and
TCG then translates that ARM64 code again for the host. This is the single
biggest performance cost in iDeck, and the main reason native ARM64 Linux games
and Proton ARM64 (where Wine and DXVK run as native arm64ec code and only the
game's x86 code goes through FEX) are the best case.

## Benchmarks

`bench/ideck_bench.c` (`ideck-bench --json [--quick]`), run in the guest from
**Performance › CPU benchmark** or by the CI boot test:

| Name | Measures |
|---|---|
| `int_single` | integer mix (xorshift, multiply, branches), Mops/s |
| `fp_single` | double-precision matmul, MFLOP/s |
| `int_multi` | the same on N threads, plus scaling factor |
| `mem_bandwidth` / `mem_read` | memcpy and streaming reads over 64 MiB, MB/s |
| `mem_latency` | dependent loads through a random cycle (Sattolo), ns |
| `syscall` | raw `getppid()`, ns/call |
| `ipc` | eight independent add chains, Gops/s |
| `jit_translate` | first call of freshly written code vs second call, µs/block; also measures re-translation after self-modifying code |

Native host numbers and guest numbers are both reported **as measured**. The
iPad figures need a device run ([TEST_RESULTS](TEST_RESULTS.md)).

The benchmark also has `fp_scalar` (an 8-body simulation in doubles: subtract,
multiply, add, square root, divide), `fp_vector` (single-precision NEON) and
`fp_convert` (an escape-time fractal: compares and int/double conversions).

## Future work: a faster translator

Henge shows a near-identity ARM64→ARM64 translator, which copies most
instructions unchanged and rewrites only loads/stores (soft-MMU TLB), branches
and system instructions. It can be much faster than TCG's IR round trip for the
same ISA. Adapting that design to QEMU's `virt` machine with virtio-gpu would be
a major project (and GPL-2.0+). It is the most promising route to large CPU gains.
