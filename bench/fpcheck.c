/*
 * iDeck FP check: runs every instruction pattern of the QEMU host-VFP
 * pass-through (engine/hostvfp_spec.py) with many operands and FPCR
 * settings and prints digests of the results.
 *
 *   ideck-fpcheck                 JSON with one digest pair per pattern
 *   ideck-fpcheck --dump NAME     every run of one pattern, one line each
 *   ideck-fpcheck --quick         fewer operand sets (smoke test)
 *
 * The same static binary runs on real hardware and inside the guest.
 * Identical digests mean the emulator computed, for every pattern, bit
 * for bit what the CPU does: all 32 V registers, NZCV, the general
 * register and (separately) the FPSR exception flags.
 *
 * AArch64 Linux only; elsewhere it prints {"fpcheck": 0}.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__) && defined(__linux__)

#include <setjmp.h>
#include <signal.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "fpcheck_cases.h"

/* Offsets are used by the assembly below. */
typedef struct {
    uint8_t v[32][16]; /*   0 */
    uint64_t fpcr;     /* 512 in  */
    uint64_t fpsr;     /* 520 out */
    uint64_t nzcv;     /* 528 in/out */
    uint64_t gpr;      /* 536 in/out: x9 */
} state;

_Static_assert(sizeof(state) == 544, "state layout");
_Static_assert(FPCHECK_GPR == 9, "the wrapper passes the general register in x9");

/*
 * fpcheck_run(state*, code): load every V register, x9, NZCV and FPCR from
 * the state, clear FPSR, call the code, and store everything back.  While
 * the code runs, x19 and x10 point to the state (the glue instructions
 * load and store through them; x10 may be advanced by post-indexed loads,
 * which is why the state sits in a page of fixed contents) and x11 is 3.
 */
void fpcheck_run(state* st, const void* code);
__asm__(
    ".text\n"
    ".balign 16\n"
    ".globl fpcheck_run\n"
    ".type fpcheck_run, %function\n"
    "fpcheck_run:\n"
    "    stp x29, x30, [sp, #-112]!\n"
    "    mov x29, sp\n"
    "    stp d8, d9, [sp, #16]\n"
    "    stp d10, d11, [sp, #32]\n"
    "    stp d12, d13, [sp, #48]\n"
    "    stp d14, d15, [sp, #64]\n"
    "    stp x19, x20, [sp, #80]\n"
    "    mov x19, x0\n"
    "    mov x20, x1\n"
    "    mrs x2, fpcr\n"
    "    str x2, [sp, #96]\n"
    "    ldp q0, q1, [x19, #0]\n"
    "    ldp q2, q3, [x19, #32]\n"
    "    ldp q4, q5, [x19, #64]\n"
    "    ldp q6, q7, [x19, #96]\n"
    "    ldp q8, q9, [x19, #128]\n"
    "    ldp q10, q11, [x19, #160]\n"
    "    ldp q12, q13, [x19, #192]\n"
    "    ldp q14, q15, [x19, #224]\n"
    "    ldp q16, q17, [x19, #256]\n"
    "    ldp q18, q19, [x19, #288]\n"
    "    ldp q20, q21, [x19, #320]\n"
    "    ldp q22, q23, [x19, #352]\n"
    "    ldp q24, q25, [x19, #384]\n"
    "    ldp q26, q27, [x19, #416]\n"
    "    ldp q28, q29, [x19, #448]\n"
    "    ldp q30, q31, [x19, #480]\n"
    "    ldr x9, [x19, #536]\n"
    "    mov x10, x19\n"
    "    mov x11, #3\n"
    "    ldr x2, [x19, #512]\n"
    "    msr fpcr, x2\n"
    "    msr fpsr, xzr\n"
    "    ldr x2, [x19, #528]\n"
    "    msr nzcv, x2\n"
    "    blr x20\n"
    "    mrs x2, nzcv\n"
    "    str x2, [x19, #528]\n"
    "    mrs x2, fpsr\n"
    "    str x2, [x19, #520]\n"
    "    str x9, [x19, #536]\n"
    "    stp q0, q1, [x19, #0]\n"
    "    stp q2, q3, [x19, #32]\n"
    "    stp q4, q5, [x19, #64]\n"
    "    stp q6, q7, [x19, #96]\n"
    "    stp q8, q9, [x19, #128]\n"
    "    stp q10, q11, [x19, #160]\n"
    "    stp q12, q13, [x19, #192]\n"
    "    stp q14, q15, [x19, #224]\n"
    "    stp q16, q17, [x19, #256]\n"
    "    stp q18, q19, [x19, #288]\n"
    "    stp q20, q21, [x19, #320]\n"
    "    stp q22, q23, [x19, #352]\n"
    "    stp q24, q25, [x19, #384]\n"
    "    stp q26, q27, [x19, #416]\n"
    "    stp q28, q29, [x19, #448]\n"
    "    stp q30, q31, [x19, #480]\n"
    "    ldr x2, [sp, #96]\n"
    "    msr fpcr, x2\n"
    "    ldp x19, x20, [sp, #80]\n"
    "    ldp d8, d9, [sp, #16]\n"
    "    ldp d10, d11, [sp, #32]\n"
    "    ldp d12, d13, [sp, #48]\n"
    "    ldp d14, d15, [sp, #64]\n"
    "    ldp x29, x30, [sp], #112\n"
    "    ret\n"
    ".size fpcheck_run, .-fpcheck_run\n"
    /*
     * Glue for the mixed sequences: instructions that are NOT on the
     * pass-through list (QEMU translates them itself) and that read or
     * write the same registers, so values flow between the two kinds.
     * The assembler encodes them; nothing here is hand-encoded.
     */
    ".section .rodata\n"
    ".balign 4\n"
    ".globl fpcheck_glue\n"
    "fpcheck_glue:\n"
    "    fmov s26, s25\n"
    "    fneg d27, d16\n"
    "    fabs v6.2d, v7.2d\n"
    "    fneg v2.4s, v3.4s\n"
    "    mov v4.16b, v3.16b\n"
    "    mov v28.16b, v0.16b\n"
    "    mov v7.16b, v30.16b\n"
    "    mov v1.16b, v2.16b\n"
    "    add v5.2d, v4.2d, v0.2d\n"
    "    sub v29.4s, v25.4s, v13.4s\n"
    "    mul v1.4s, v2.4s, v0.4s\n"
    "    eor v6.16b, v5.16b, v1.16b\n"
    "    and v10.16b, v26.16b, v27.16b\n"
    "    orr v0.16b, v1.16b, v2.16b\n"
    "    not v3.16b, v4.16b\n"
    "    bsl v0.16b, v1.16b, v2.16b\n"
    "    bit v3.16b, v4.16b, v5.16b\n"
    "    cmeq v0.4s, v1.4s, v2.4s\n"
    "    ushr v3.2d, v4.2d, #7\n"
    "    sshr d5, d6, #3\n"
    "    shl v11.2d, v4.2d, #3\n"
    "    xtn v4.4h, v5.4s\n"
    "    uxtl v6.2d, v7.2s\n"
    "    rev64 v1.16b, v2.16b\n"
    "    ext v8.16b, v0.16b, v25.16b, #5\n"
    "    zip1 v9.4s, v1.4s, v30.4s\n"
    "    uzp2 v2.8h, v3.8h, v0.8h\n"
    "    movi v6.16b, #0x55\n"
    "    movi d5, #0xff00ff00ff00ff00\n"
    "    mvni v3.4s, #0x12\n"
    "    fmov d2, #1.5\n"
    "    fmov s15, #-0.25\n"
    "    fmov d0, #-2.0\n"
    "    fcsel d5, d0, d1, ne\n"
    "    fcsel s14, s26, s7, ge\n"
    "    fcsel d1, d2, d3, mi\n"
    "    fcvt h3, d4\n"
    "    fcvt d5, h3\n"
    "    fcvt s2, h1\n"
    "    sqadd v1.4s, v2.4s, v3.4s\n"
    "    uqsub v4.8b, v5.8b, v6.8b\n"
    "    cnt v0.8b, v1.8b\n"
    "    addv s2, v3.4s\n"
    "    umaxv b4, v5.16b\n"
    "    sqrdmulh v0.4s, v1.4s, v2.4s\n"
    "    uaddlv h3, v4.16b\n"
    "    fmov x9, d6\n"
    "    fmov w9, s31\n"
    "    fmov x9, d1\n"
    "    fmov d7, x9\n"
    "    fmov s30, w9\n"
    "    fmov d0, x9\n"
    "    fmov v2.d[1], x9\n"
    "    fmov x9, v3.d[1]\n"
    "    mov v0.d[1], v7.d[0]\n"
    "    mov v16.s[2], v4.s[1]\n"
    "    mov v3.d[0], x9\n"
    "    dup v1.4s, w9\n"
    "    dup v31.2d, x9\n"
    "    dup v5.2d, v0.d[1]\n"
    "    umov w9, v2.s[1]\n"
    "    mov x9, v27.d[1]\n"
    "    mov x9, v0.d[0]\n"
    "    ldr d3, [x19, #8]\n"
    "    ldr s7, [x19, #100]\n"
    "    ldr q12, [x19, #400]\n"
    "    ldr q0, [x19, #16]\n"
    "    ldr d1, [x19, #24]\n"
    "    ldr d2, [x19, x11, lsl #3]\n"
    "    ldr s4, [x19, x11]\n"
    "    ldur d6, [x19, #9]\n"
    "    ldur q1, [x19, #33]\n"
    "    ldur s0, [x19, #3]\n"
    "    ldr d4, [x10], #16\n"
    "    ldr q5, [x10, #32]!\n"
    "    ldr s2, [x10], #8\n"
    "    ldr d0, [x10, #8]!\n"
    "    ldp d1, d2, [x19, #48]\n"
    "    ldp q3, q0, [x19, #64]\n"
    "    ldp s4, s5, [x19, #16]\n"
    "    ldnp d2, d3, [x19, #128]\n"
    "    ldp d5, d0, [x10], #16\n"
    "    ldp q1, q4, [x10, #32]!\n"
    "    ld1 {v4.16b, v5.16b}, [x19]\n"
    "    ld1 {v0.2d}, [x19]\n"
    "    ld1r {v1.4s}, [x19]\n"
    "    ld2 {v2.4s, v3.4s}, [x19]\n"
    "    ld1 {v6.d}[1], [x19]\n"
    "    ld1 {v0.16b, v1.16b, v2.16b}, [x10], #48\n"
    "    str q4, [x19, #32]\n"
    "    str d25, [x19, #488]\n"
    "    str s1, [x19, #500]\n"
    "    stur d2, [x19, #33]\n"
    "    stp d0, d1, [x19, #440]\n"
    "    stp q2, q3, [x19, #448]\n"
    "    st1 {v0.16b}, [x19]\n"
    "    ldr x9, [x19, #536]\n"
    "    str x9, [x19, #536]\n"
    "    ldr w9, [x19, #4]\n"
    "    ldrb w9, [x10], #1\n"
    "    adds x9, x9, x9\n"
    "    cmn x9, #1\n"
    "    cmp x9, #0\n"
    "    ccmp x9, x11, #4, ne\n"
    ".globl fpcheck_glue_end\n"
    "fpcheck_glue_end:\n"
    ".text\n");
extern const uint32_t fpcheck_glue[], fpcheck_glue_end[];

#define RET_INSN 0xd65f03c0u

/* ---- operands ----------------------------------------------------------- */

static uint64_t rng_state;

static uint64_t rng(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return rng_state = x;
}

static const uint64_t special64[] = {
    0x0000000000000000ull, 0x8000000000000000ull, /* +-0 */
    0x3ff0000000000000ull, 0xbff0000000000000ull, /* +-1 */
    0x4000000000000000ull, 0x3fe0000000000000ull, /* 2, 0.5 */
    0x3ff8000000000000ull, 0xbff8000000000000ull, /* +-1.5 */
    0x4004000000000000ull, 0xc004000000000000ull, /* +-2.5 */
    0x3fb999999999999aull, 0x3fd5555555555555ull, /* 0.1, 1/3 */
    0x400921fb54442d18ull, 0xc00921fb54442d18ull, /* +-pi */
    0x0000000000000001ull, 0x800fffffffffffffull, /* denormals */
    0x0010000000000000ull, 0x7fefffffffffffffull, /* DBL_MIN, DBL_MAX */
    0x7ff0000000000000ull, 0xfff0000000000000ull, /* +-inf */
    0x7ff8000000000000ull, 0xfff8000000001234ull, /* quiet NaNs */
    0x7ff0000000000001ull, 0xfff4000000000000ull, /* signalling NaNs */
    0x41dfffffffc00000ull, 0xc1e0000000000000ull, /* INT32_MAX, INT32_MIN */
    0x41dfffffffe00000ull, 0x41efffffffe00000ull, /* 2147483647.5, 4294967295 */
    0x43e0000000000000ull, 0xc3e0000000000000ull, /* +-2^63 */
    0x43f0000000000000ull, 0x4340000000000001ull, /* 2^64, 2^53+2 */
    0x7e37e43c8800759cull, 0x01a56e1fc2f8f359ull, /* 1e300, 1e-300 */
    0x0020000000000000ull, 0x3cb0000000000000ull, /* 2*DBL_MIN, 2^-52 */
};

static const uint32_t special32[] = {
    0x00000000u, 0x80000000u, 0x3f800000u, 0xbf800000u, 0x40000000u, 0x3f000000u,
    0x3fc00000u, 0xbfc00000u, 0x40200000u, 0xc0200000u, 0x3dcccccdu, 0x3eaaaaabu,
    0x40490fdbu, 0xc0490fdbu, 0x00000001u, 0x807fffffu, 0x00800000u, 0x7f7fffffu,
    0x7f800000u, 0xff800000u, 0x7fc00000u, 0xffc01234u, 0x7f800001u, 0xffa00000u,
    0x4f000000u, 0xcf000000u, 0x4f800000u, 0x5f000000u, 0xdf000000u, 0x5f800000u,
    0x7149f2cau, 0x0da24260u, 0x01000000u, 0x34000000u, 0x4b800001u, 0x3effffffu,
};

static const uint64_t special_int[] = {
    0, 1, (uint64_t)-1, 2, 0x7fffffffull, 0x80000000ull, 0xffffffffull, 0x100000000ull,
    0x7fffffffffffffffull, 0x8000000000000000ull, 0x20000000000001ull, 0xfffffffffffff801ull,
    0x123456789abcdefull, 1000000, (uint64_t)-1000000, 0x8000000000000401ull,
};

#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))

static uint64_t pick64(void) {
    uint64_t r = rng();
    switch (r & 7) {
    case 0:
    case 1:
    case 2:
        return special64[(r >> 8) % ARRAY_LEN(special64)];
    case 3:
    case 4:
        return (uint64_t)special32[(r >> 8) % ARRAY_LEN(special32)] |
               ((uint64_t)special32[(r >> 24) % ARRAY_LEN(special32)] << 32);
    case 5: {
        /* A normal double of moderate size and a random fraction. */
        uint64_t exp = 1023 - 40 + ((r >> 8) % 80);
        return ((r >> 63) << 63) | (exp << 52) | (rng() >> 12);
    }
    case 6: {
        /* Two normal floats. */
        uint64_t a = rng();
        uint32_t lo = (uint32_t)(((a >> 31) & 1) << 31 | (127 - 20 + (a % 40)) << 23 | ((a >> 8) & 0x7fffff));
        uint32_t hi = (uint32_t)(((a >> 63) & 1) << 31 | (127 - 20 + ((a >> 32) % 40)) << 23 |
                                 ((a >> 40) & 0x7fffff));
        return lo | ((uint64_t)hi << 32);
    }
    default:
        return rng();
    }
}

static void fill_state(state* st, uint64_t seed, uint64_t fpcr) {
    rng_state = seed * 0x9e3779b97f4a7c15ull + 0x1234567ull;
    if (!rng_state) rng_state = 1;
    for (int r = 0; r < 32; ++r) {
        uint64_t lo = pick64(), hi = pick64();
        memcpy(st->v[r], &lo, 8);
        memcpy(st->v[r] + 8, &hi, 8);
    }
    uint64_t r = rng();
    st->gpr = (r & 3) ? special_int[(r >> 8) % ARRAY_LEN(special_int)] : rng();
    st->nzcv = ((r >> 40) & 0xf) << 28;
    st->fpcr = fpcr;
    st->fpsr = 0;
}

/* FPCR settings every ARMv8.0 CPU has: rounding modes, FZ, DN, AHP. */
static const uint64_t fpcr_modes[] = {
    0x00000000, /* round to nearest */
    0x00400000, /* towards +inf */
    0x00800000, /* towards -inf */
    0x00c00000, /* towards zero */
    0x01000000, /* FZ */
    0x02000000, /* DN */
    0x03c00000, /* FZ, DN, towards zero */
    0x04000000, /* AHP */
};

/* ---- digests -------------------------------------------------------------- */

static uint64_t fnv(uint64_t h, const void* data, size_t n) {
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < n; ++i) {
        h ^= p[i];
        h *= 0x100000001b3ull;
    }
    return h;
}

#define FNV_INIT 0xcbf29ce484222325ull
/* Cumulative exception bits and QC. */
#define FPSR_MASK 0x0800009full

static uint64_t hash_values(uint64_t h, const state* st) {
    h = fnv(h, st->v, sizeof(st->v));
    h = fnv(h, &st->nzcv, 8);
    return fnv(h, &st->gpr, 8);
}

static uint64_t hash_flags(uint64_t h, const state* st) {
    uint64_t f = st->fpsr & FPSR_MASK;
    return fnv(h, &f, 8);
}

/* ---- running generated code ------------------------------------------------ */

/* The state, in a page whose other bytes never change (see fpcheck_run). */
static union {
    state st;
    uint8_t page[4096];
} g_buf __attribute__((aligned(64)));

static uint32_t* g_code;
static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_armed;
static uint64_t g_fpcr_default;

static void on_sigill(int sig) {
    (void)sig;
    if (!g_armed) _exit(3);
    siglongjmp(g_jmp, 1);
}

/* Returns 0, or 1 if the code raised SIGILL. */
static int run_code(state* st, const uint32_t* insns, int n) {
    for (int i = 0; i < n; ++i) g_code[i] = insns[i];
    g_code[n] = RET_INSN;
    __builtin___clear_cache((char*)g_code, (char*)(g_code + n + 1));
    if (sigsetjmp(g_jmp, 1)) {
        g_armed = 0;
        __asm__ volatile("msr fpcr, %0" : : "r"(g_fpcr_default));
        return 1;
    }
    g_armed = 1;
    fpcheck_run(st, g_code);
    g_armed = 0;
    return 0;
}

static int rerun(state* st) {
    if (sigsetjmp(g_jmp, 1)) {
        g_armed = 0;
        __asm__ volatile("msr fpcr, %0" : : "r"(g_fpcr_default));
        return 1;
    }
    g_armed = 1;
    fpcheck_run(st, g_code);
    g_armed = 0;
    return 0;
}

static int have_feat(unsigned feat) {
    unsigned long hw = getauxval(AT_HWCAP);
    switch (feat) {
    case 0: return 1;
    case 1: return (hw >> 13) & 1; /* JSCVT */
    case 2: return (hw >> 3) & 1;  /* AES */
    case 3: return (hw >> 5) & 1;  /* SHA1 */
    case 4: return (hw >> 6) & 1;  /* SHA2 */
    case 5: return (hw >> 4) & 1;  /* PMULL */
    default: return 0;
    }
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void print_hex128(const uint8_t* p) {
    uint64_t lo, hi;
    memcpy(&lo, p, 8);
    memcpy(&hi, p + 8, 8);
    printf("%016llx%016llx", (unsigned long long)hi, (unsigned long long)lo);
}

int main(int argc, char** argv) {
    int quick = 0;
    const char* dump = NULL;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--quick")) quick = 1;
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
        else {
            fprintf(stderr, "usage: ideck-fpcheck [--quick] [--dump PATTERN]\n");
            return 2;
        }
    }

    g_code = (uint32_t*)mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g_code == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    __asm__ volatile("mrs %0, fpcr" : "=r"(g_fpcr_default));
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigill;
    sigaction(SIGILL, &sa, NULL);

    const int nsets = quick ? 4 : 24;
    const int nmodes = (int)ARRAY_LEN(fpcr_modes);
    static uint64_t pat_values[FPCHECK_NPATTERNS], pat_flags[FPCHECK_NPATTERNS];
    static unsigned char pat_sigill[FPCHECK_NPATTERNS], pat_skipped[FPCHECK_NPATTERNS];
    static unsigned char pat_ran[FPCHECK_NPATTERNS];
    for (int i = 0; i < FPCHECK_NPATTERNS; ++i) pat_values[i] = pat_flags[i] = FNV_INIT;

    for (size_t i = sizeof(state); i < sizeof(g_buf.page); ++i)
        g_buf.page[i] = (uint8_t)(i * 131u + (i >> 8) * 29u + 7u);
#define st (g_buf.st)
    uint64_t runs = 0;
    double t0 = now_s();

    for (int c = 0; c < FPCHECK_NCASES; ++c) {
        unsigned pat = fpcheck_cases[c].pat;
        uint32_t insn = fpcheck_cases[c].insn;
        if (dump && strcmp(dump, fpcheck_names[pat])) continue;
        if (!have_feat(fpcheck_feat[pat])) {
            pat_skipped[pat] = 1;
            continue;
        }
        if (pat_sigill[pat]) continue;
        pat_ran[pat] = 1;
        for (int m = 0; m < nmodes; ++m) {
            for (int s = 0; s < nsets; ++s) {
                fill_state(&st, (uint64_t)s * 1000003u + (uint64_t)c, fpcr_modes[m]);
                int ill = (m == 0 && s == 0) ? run_code(&st, &insn, 1) : rerun(&st);
                if (ill) {
                    pat_sigill[pat] = 1;
                    goto next_case;
                }
                ++runs;
                pat_values[pat] = hash_values(pat_values[pat], &st);
                pat_flags[pat] = hash_flags(pat_flags[pat], &st);
                if (dump) {
                    printf("%08x m%d s%02d rd=", insn, m, s);
                    print_hex128(st.v[insn & 31]);
                    printf(" x9=%016llx nzcv=%x fpsr=%02llx all=%016llx\n",
                           (unsigned long long)st.gpr, (unsigned)(st.nzcv >> 28),
                           (unsigned long long)(st.fpsr & FPSR_MASK),
                           (unsigned long long)hash_values(FNV_INIT, &st));
                }
            }
        }
    next_case:;
    }
    double t_single = now_s() - t0;
    if (dump) return 0;

    /*
     * Mixed sequences: several listed instructions and glue instructions
     * in one block, so results pass through guest registers between
     * instructions the emulator handles in two different ways.
     */
    uint64_t mix_values = FNV_INIT, mix_flags = FNV_INIT, mix_runs = 0, mix_sigill = 0;
    const int nglue = (int)(fpcheck_glue_end - fpcheck_glue);
    const int nseq = quick ? 1500 : 30000;
    double t1 = now_s();
    for (int q = 0; q < nseq; ++q) {
        uint32_t seq[40];
        int len = 0;
        uint64_t pr = (uint64_t)q * 0x2545f4914f6cdd1dull + 99;
        /* Even sequences: any register. Odd: listed instructions among
           V0-V6 only, and more of them, so they feed each other. */
        const int dense = q & 1;
        const int want = 6 + (int)((unsigned)q % 27u);
        for (int k = 0; k < 4 * want && len < want; ++k) {
            pr ^= pr << 13;
            pr ^= pr >> 7;
            pr ^= pr << 17;
            if ((pr & 0xff) < (dense ? 205u : 150u)) {
                int c = (int)((pr >> 8) % FPCHECK_NCASES);
                unsigned pat = fpcheck_cases[c].pat;
                if (!have_feat(fpcheck_feat[pat]) || pat_sigill[pat]) continue;
                if (dense && !fpcheck_cases[c].low) continue;
                seq[len++] = fpcheck_cases[c].insn;
            } else {
                seq[len++] = fpcheck_glue[(pr >> 8) % (uint64_t)nglue];
            }
        }
        for (int s2 = 0; s2 < 3; ++s2) {
            fill_state(&st, 777u + (uint64_t)q * 31u + (uint64_t)s2, fpcr_modes[(q + s2) % nmodes]);
            int ill = s2 == 0 ? run_code(&st, seq, len) : rerun(&st);
            if (ill) {
                ++mix_sigill;
                break;
            }
            ++mix_runs;
            mix_values = hash_values(mix_values, &st);
            mix_flags = hash_flags(mix_flags, &st);
        }
    }
    double t_mix = now_s() - t1;

    uint64_t all_values = FNV_INIT, all_flags = FNV_INIT;
    int nran = 0, nill = 0, nskip = 0;
    for (int i = 0; i < FPCHECK_NPATTERNS; ++i) {
        if (pat_sigill[i]) ++nill;
        else if (pat_ran[i]) {
            ++nran;
            all_values = fnv(all_values, &pat_values[i], 8);
            all_flags = fnv(all_flags, &pat_flags[i], 8);
        } else if (pat_skipped[i]) ++nskip;
    }

    printf("{\n  \"fpcheck\": 1,\n  \"patterns_total\": %d,\n  \"patterns_run\": %d,\n", FPCHECK_NPATTERNS,
           nran);
    printf("  \"cases\": %d,\n  \"runs\": %llu,\n  \"seconds\": %.3f,\n", FPCHECK_NCASES,
           (unsigned long long)runs, t_single);
    printf("  \"values\": \"%016llx\",\n  \"flags\": \"%016llx\",\n", (unsigned long long)all_values,
           (unsigned long long)all_flags);
    printf("  \"mix_runs\": %llu,\n  \"mix_sigill\": %llu,\n  \"mix_seconds\": %.3f,\n",
           (unsigned long long)mix_runs, (unsigned long long)mix_sigill, t_mix);
    printf("  \"mix_values\": \"%016llx\",\n  \"mix_flags\": \"%016llx\",\n", (unsigned long long)mix_values,
           (unsigned long long)mix_flags);
    printf("  \"sigill\": [");
    for (int i = 0, n = 0; i < FPCHECK_NPATTERNS; ++i)
        if (pat_sigill[i]) printf("%s\"%s\"", n++ ? ", " : "", fpcheck_names[i]);
    printf("],\n  \"skipped\": [");
    for (int i = 0, n = 0; i < FPCHECK_NPATTERNS; ++i)
        if (pat_skipped[i] && !pat_ran[i]) printf("%s\"%s\"", n++ ? ", " : "", fpcheck_names[i]);
    printf("],\n  \"patterns\": {\n");
    for (int i = 0, n = 0; i < FPCHECK_NPATTERNS; ++i) {
        if (!pat_ran[i] || pat_sigill[i]) continue;
        printf("%s    \"%s\": [\"%016llx\", \"%016llx\"]", n++ ? ",\n" : "", fpcheck_names[i],
               (unsigned long long)pat_values[i], (unsigned long long)pat_flags[i]);
    }
    printf("\n  }\n}\n");
    (void)nskip;
    return nill || mix_sigill ? 1 : 0;
#undef st
}

#else

int main(void) {
    printf("{\"fpcheck\": 0, \"note\": \"AArch64 Linux only\"}\n");
    return 0;
}

#endif
