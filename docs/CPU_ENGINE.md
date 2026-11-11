# CPU engine

## What runs the guest

**QEMU 10.0.12 (utmapp fork), TCG**, multi-threaded (one host thread per vCPU),
started in-process. QEMU is not reimplemented. The prompt said not to write a new
emulator where an existing one achieves the result, and on iPadOS no hypervisor is
available, so a binary translator is the only option.

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

## Future work: a faster translator

Henge shows a near-identity ARM64→ARM64 translator, which copies most
instructions unchanged and rewrites only loads/stores (soft-MMU TLB), branches
and system instructions. It can be much faster than TCG's IR round trip for the
same ISA. Adapting that design to QEMU's `virt` machine with virtio-gpu would be
a major project (and GPL-2.0+). It is the most promising route to large CPU gains.
