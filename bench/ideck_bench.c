/*
 * ideck-bench — CPU and memory micro-benchmarks for the iDeck guest.
 *
 * Runs inside the Linux guest (where it measures the emulated CPU: TCG JIT
 * or interpreter) and natively on hosts for a baseline. Every result is a
 * measurement taken on the machine the binary runs on; nothing is modelled.
 *
 *   ideck-bench [--json] [--quick] [--threads N]
 *
 * Benchmarks
 *   int_single     integer mix (xorshift + multiply + branches), Mops/s
 *   fp_single      double-precision dense matmul, MFLOP/s
 *   int_multi      int_single on N threads, aggregate Mops/s + scaling
 *   mem_bandwidth  memcpy over a 64 MiB buffer, MB/s
 *   mem_read       streaming 64-bit reads, MB/s
 *   mem_latency    dependent loads through a random cycle, ns/load
 *   syscall        getppid() round trip, ns/call
 *   ipc            independent adds per second (instruction throughput)
 *   jit_translate  cold vs warm execution of freshly written code, us/block
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#endif

/* ---- platform shims --------------------------------------------------- */

static double now_s(void) {
#if defined(_WIN32)
    static LARGE_INTEGER freq;
    LARGE_INTEGER c;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)freq.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
#endif
}

static int cpu_count(void) {
#if defined(_WIN32)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (int)si.dwNumberOfProcessors;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 1;
#endif
}

typedef void* (*thread_fn)(void*);

#if defined(_WIN32)
typedef struct {
    thread_fn fn;
    void* arg;
} win_thunk;
static DWORD WINAPI win_entry(LPVOID p) {
    win_thunk* t = (win_thunk*)p;
    t->fn(t->arg);
    return 0;
}
#endif

static void run_threads(int n, thread_fn fn, void** args) {
#if defined(_WIN32)
    HANDLE h[64];
    win_thunk th[64];
    for (int i = 0; i < n; ++i) {
        th[i].fn = fn;
        th[i].arg = args[i];
        h[i] = CreateThread(NULL, 0, win_entry, &th[i], 0, NULL);
    }
    WaitForMultipleObjects((DWORD)n, h, TRUE, INFINITE);
    for (int i = 0; i < n; ++i) CloseHandle(h[i]);
#else
    pthread_t t[64];
    for (int i = 0; i < n; ++i) pthread_create(&t[i], NULL, fn, args[i]);
    for (int i = 0; i < n; ++i) pthread_join(t[i], NULL);
#endif
}

/* Defeats dead-code elimination without adding work to the measured loop. */
static volatile uint64_t g_sink;

/* ---- results ----------------------------------------------------------- */

typedef struct {
    const char* name;
    const char* unit;
    double value;
    double seconds;
    char note[96];
    int ok;
} result;

static result g_results[16];
static int g_nresults;

static result* add_result(const char* name, const char* unit) {
    result* r = &g_results[g_nresults++];
    memset(r, 0, sizeof(*r));
    r->name = name;
    r->unit = unit;
    return r;
}

/* ---- integer ----------------------------------------------------------- */

static uint64_t int_kernel(uint64_t iters, uint64_t seed) {
    uint64_t x = seed | 1, acc = 0;
    for (uint64_t i = 0; i < iters; ++i) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        uint64_t m = x * 0x9E3779B97F4A7C15ull;
        if (m & 1) acc += m >> 3;
        else acc ^= m << 1;
        acc = (acc << 5) | (acc >> 59);
    }
    return acc;
}
/* One iteration is ~12 integer operations. */
#define INT_OPS_PER_ITER 12.0

static void bench_int_single(uint64_t iters) {
    result* r = add_result("int_single", "Mops/s");
    double t0 = now_s();
    g_sink = int_kernel(iters, 42);
    double dt = now_s() - t0;
    r->seconds = dt;
    r->value = (double)iters * INT_OPS_PER_ITER / dt / 1e6;
    r->ok = 1;
}

typedef struct {
    uint64_t iters;
    uint64_t seed;
    uint64_t out;
} int_job;

static void* int_thread(void* p) {
    int_job* j = (int_job*)p;
    j->out = int_kernel(j->iters, j->seed);
    return NULL;
}

static void bench_int_multi(uint64_t iters, int threads, double single_mops) {
    result* r = add_result("int_multi", "Mops/s");
    if (threads > 64) threads = 64;
    int_job jobs[64];
    void* args[64];
    for (int i = 0; i < threads; ++i) {
        jobs[i].iters = iters;
        jobs[i].seed = (uint64_t)i * 7919 + 1;
        args[i] = &jobs[i];
    }
    double t0 = now_s();
    run_threads(threads, int_thread, args);
    double dt = now_s() - t0;
    uint64_t s = 0;
    for (int i = 0; i < threads; ++i) s ^= jobs[i].out;
    g_sink = s;
    r->seconds = dt;
    r->value = (double)iters * threads * INT_OPS_PER_ITER / dt / 1e6;
    snprintf(r->note, sizeof(r->note), "%d threads, scaling %.2fx of single", threads,
             single_mops > 0 ? r->value / single_mops : 0.0);
    r->ok = 1;
}

/* ---- floating point ---------------------------------------------------- */

static void bench_fp_single(int n) {
    result* r = add_result("fp_single", "MFLOP/s");
    double* a = (double*)malloc(sizeof(double) * (size_t)n * (size_t)n);
    double* b = (double*)malloc(sizeof(double) * (size_t)n * (size_t)n);
    double* c = (double*)calloc((size_t)n * (size_t)n, sizeof(double));
    if (!a || !b || !c) {
        snprintf(r->note, sizeof(r->note), "allocation failed");
        free(a); free(b); free(c);
        return;
    }
    for (int i = 0; i < n * n; ++i) {
        a[i] = (double)(i % 17) * 0.25;
        b[i] = (double)(i % 13) * 0.5;
    }
    double t0 = now_s();
    for (int i = 0; i < n; ++i)
        for (int k = 0; k < n; ++k) {
            double aik = a[i * n + k];
            for (int j = 0; j < n; ++j) c[i * n + j] += aik * b[k * n + j];
        }
    double dt = now_s() - t0;
    double check = 0;
    for (int i = 0; i < n * n; i += n + 1) check += c[i];
    g_sink = (uint64_t)check;
    r->seconds = dt;
    r->value = 2.0 * n * (double)n * n / dt / 1e6;
    snprintf(r->note, sizeof(r->note), "%dx%d matmul", n, n);
    r->ok = 1;
    free(a); free(b); free(c);
}

/* ---- memory ------------------------------------------------------------ */

static void bench_memory(size_t bytes, int reps) {
    result* bw = add_result("mem_bandwidth", "MB/s");
    result* rd = add_result("mem_read", "MB/s");
    uint8_t* src = (uint8_t*)malloc(bytes);
    uint8_t* dst = (uint8_t*)malloc(bytes);
    if (!src || !dst) {
        snprintf(bw->note, sizeof(bw->note), "allocation failed");
        free(src); free(dst);
        return;
    }
    memset(src, 0x5A, bytes);
    memset(dst, 0, bytes); /* fault pages in before timing */
    double t0 = now_s();
    for (int i = 0; i < reps; ++i) {
        memcpy(dst, src, bytes);
        src[i & 4095] ^= (uint8_t)i;
    }
    double dt = now_s() - t0;
    g_sink = dst[bytes / 2];
    bw->seconds = dt;
    /* memcpy moves `bytes` in and `bytes` out per rep; report copy rate. */
    bw->value = (double)bytes * reps / dt / 1e6;
    snprintf(bw->note, sizeof(bw->note), "memcpy %zu MiB x%d", bytes >> 20, reps);
    bw->ok = 1;

    const uint64_t* p = (const uint64_t*)src;
    size_t words = bytes / 8;
    uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    t0 = now_s();
    for (int r = 0; r < reps; ++r)
        for (size_t i = 0; i + 4 <= words; i += 4) {
            s0 += p[i];
            s1 += p[i + 1];
            s2 += p[i + 2];
            s3 += p[i + 3];
        }
    dt = now_s() - t0;
    g_sink = s0 ^ s1 ^ s2 ^ s3;
    rd->seconds = dt;
    rd->value = (double)bytes * reps / dt / 1e6;
    rd->ok = 1;
    free(src);
    free(dst);
}

static void bench_latency(size_t bytes, uint64_t loads) {
    result* r = add_result("mem_latency", "ns/load");
    size_t n = bytes / sizeof(size_t);
    size_t* next = (size_t*)malloc(n * sizeof(size_t));
    size_t* order = (size_t*)malloc(n * sizeof(size_t));
    if (!next || !order) {
        snprintf(r->note, sizeof(r->note), "allocation failed");
        free(next); free(order);
        return;
    }
    /* Random single cycle (Sattolo) so hardware prefetchers cannot help. */
    for (size_t i = 0; i < n; ++i) order[i] = i;
    uint64_t x = 88172645463325252ull;
    for (size_t i = n - 1; i > 0; --i) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        size_t j = (size_t)(x % i);
        size_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (size_t i = 0; i < n; ++i) next[order[i]] = order[(i + 1) % n];
    free(order);
    size_t cur = 0;
    for (size_t i = 0; i < n; ++i) cur = next[cur]; /* warm TLB/pages */
    double t0 = now_s();
    for (uint64_t i = 0; i < loads; ++i) cur = next[cur];
    double dt = now_s() - t0;
    g_sink = cur;
    r->seconds = dt;
    r->value = dt / (double)loads * 1e9;
    snprintf(r->note, sizeof(r->note), "random cycle over %zu MiB", bytes >> 20);
    r->ok = 1;
    free(next);
}

/* ---- system calls ------------------------------------------------------ */

static void bench_syscall(uint64_t calls) {
    result* r = add_result("syscall", "ns/call");
#if defined(__linux__)
    double t0 = now_s();
    uint64_t s = 0;
    for (uint64_t i = 0; i < calls; ++i) s += (uint64_t)syscall(SYS_getppid);
    double dt = now_s() - t0;
    g_sink = s;
    r->seconds = dt;
    r->value = dt / (double)calls * 1e9;
    snprintf(r->note, sizeof(r->note), "raw getppid()");
    r->ok = 1;
#else
    (void)calls;
    snprintf(r->note, sizeof(r->note), "not measured on this OS");
#endif
}

/* ---- instruction throughput ------------------------------------------- */

static void bench_ipc(uint64_t iters) {
    result* r = add_result("ipc", "Gops/s");
    uint64_t a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8;
    double t0 = now_s();
    for (uint64_t i = 0; i < iters; ++i) {
        /* Eight independent dependency chains: limited by issue width. */
        a += i; b += a ^ i; c += i; d += c ^ i;
        e += i; f += e ^ i; g += i; h += g ^ i;
#if defined(__GNUC__)
        __asm__ volatile("" : "+r"(a), "+r"(c), "+r"(e), "+r"(g));
#endif
    }
    double dt = now_s() - t0;
    g_sink = a ^ b ^ c ^ d ^ e ^ f ^ g ^ h;
    r->seconds = dt;
    r->value = (double)iters * 12.0 / dt / 1e9;
    snprintf(r->note, sizeof(r->note), "8 independent add chains");
    r->ok = 1;
}

/* ---- JIT translation overhead ----------------------------------------- */

/*
 * Writes `blocks` distinct small functions into fresh executable memory and
 * times their first call (the emulator must translate each one) against a
 * second call (served from the translation cache). On native hardware the
 * difference is only cache/TLB misses; under QEMU TCG it is the cost of
 * translating a block. Then rewrites the code to measure invalidation.
 */
#if !defined(_WIN32) && (defined(__aarch64__) || defined(__x86_64__))
#define HAVE_JIT_BENCH 1
#endif

#ifdef HAVE_JIT_BENCH
enum { FN_INSNS = 32 };

static size_t emit_fn(uint8_t* p, uint32_t k) {
#if defined(__aarch64__)
    uint32_t* w = (uint32_t*)p;
    size_t n = 0;
    w[n++] = 0x52800000u | ((k & 0xFFFFu) << 5);           /* movz w0, #k */
    for (int i = 0; i < FN_INSNS; ++i)
        w[n++] = 0x11000400u | ((uint32_t)(i & 7) << 10);  /* add w0, w0, #(1 + (i&7)<<?) */
    w[n++] = 0xD65F03C0u;                                  /* ret */
    return n * 4;
#else
    size_t n = 0;
    p[n++] = 0xB8; /* mov eax, imm32 */
    memcpy(p + n, &k, 4);
    n += 4;
    for (int i = 0; i < FN_INSNS; ++i) {
        p[n++] = 0x83; p[n++] = 0xC0; p[n++] = (uint8_t)(1 + (i & 7)); /* add eax, imm8 */
    }
    p[n++] = 0xC3; /* ret */
    return n;
#endif
}

static void bench_jit(int blocks) {
    result* r = add_result("jit_translate", "us/block");
    size_t stride = 512;
    size_t len = (size_t)blocks * stride;
    uint8_t* mem = (uint8_t*)mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) {
        snprintf(r->note, sizeof(r->note), "W+X mapping refused");
        return;
    }
    typedef uint32_t (*fn_t)(void);
    for (int i = 0; i < blocks; ++i) emit_fn(mem + (size_t)i * stride, (uint32_t)i);
    __builtin___clear_cache((char*)mem, (char*)mem + len);

    uint64_t s = 0;
    double t0 = now_s();
    for (int i = 0; i < blocks; ++i) s += ((fn_t)(void*)(mem + (size_t)i * stride))();
    double cold = now_s() - t0;
    t0 = now_s();
    for (int i = 0; i < blocks; ++i) s += ((fn_t)(void*)(mem + (size_t)i * stride))();
    double warm = now_s() - t0;

    /* Rewrite every function (self-modifying code) and call again. */
    for (int i = 0; i < blocks; ++i) emit_fn(mem + (size_t)i * stride, (uint32_t)(i + 1));
    __builtin___clear_cache((char*)mem, (char*)mem + len);
    t0 = now_s();
    for (int i = 0; i < blocks; ++i) s += ((fn_t)(void*)(mem + (size_t)i * stride))();
    double rewrite = now_s() - t0;
    g_sink = s;
    munmap(mem, len);

    r->seconds = cold + warm + rewrite;
    r->value = (cold - warm) / blocks * 1e6;
    snprintf(r->note, sizeof(r->note), "cold %.2f warm %.3f rewrite %.2f us/block", cold / blocks * 1e6,
             warm / blocks * 1e6, rewrite / blocks * 1e6);
    r->ok = 1;
}
#endif

/* ---- driver ------------------------------------------------------------ */

static void print_json(int threads, int quick) {
    printf("{\n  \"tool\": \"ideck-bench\",\n  \"version\": \"0.1.0\",\n");
#if defined(__aarch64__)
    const char* arch = "aarch64";
#elif defined(__x86_64__) || defined(_M_X64)
    const char* arch = "x86_64";
#else
    const char* arch = "unknown";
#endif
    printf("  \"arch\": \"%s\",\n  \"cpus\": %d,\n  \"threads\": %d,\n  \"quick\": %s,\n", arch, cpu_count(),
           threads, quick ? "true" : "false");
    printf("  \"results\": [\n");
    for (int i = 0; i < g_nresults; ++i) {
        result* r = &g_results[i];
        printf("    {\"name\": \"%s\", \"unit\": \"%s\", \"ok\": %s, \"value\": %.4f, \"seconds\": %.4f, "
               "\"note\": \"%s\"}%s\n",
               r->name, r->unit, r->ok ? "true" : "false", r->value, r->seconds, r->note,
               i + 1 < g_nresults ? "," : "");
    }
    printf("  ]\n}\n");
}

int main(int argc, char** argv) {
    int json = 0, quick = 0, threads = cpu_count();
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--quick")) quick = 1;
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
        else {
            fprintf(stderr, "usage: ideck-bench [--json] [--quick] [--threads N]\n");
            return 2;
        }
    }
    if (threads < 1) threads = 1;
    if (threads > 64) threads = 64;

    /* Sizes chosen to run ~1-3 s each on a native core; scaled down by
       --quick for interpreter builds where everything is far slower. */
    uint64_t int_iters = quick ? 2000000ull : 50000000ull;
    int fp_n = quick ? 96 : 384;
    size_t mem = (size_t)(quick ? 16 : 64) << 20;
    int mem_reps = quick ? 2 : 8;

    bench_int_single(int_iters);
    double single = g_results[g_nresults - 1].value;
    bench_fp_single(fp_n);
    bench_int_multi(int_iters, threads, single);
    bench_memory(mem, mem_reps);
    bench_latency(mem, quick ? 2000000ull : 20000000ull);
    bench_syscall(quick ? 100000ull : 2000000ull);
    bench_ipc(quick ? 20000000ull : 400000000ull);
#ifdef HAVE_JIT_BENCH
    bench_jit(quick ? 512 : 4096);
#else
    {
        result* r = add_result("jit_translate", "us/block");
        snprintf(r->note, sizeof(r->note), "not measured on this OS/arch");
    }
#endif

    if (json) {
        print_json(threads, quick);
    } else {
        for (int i = 0; i < g_nresults; ++i) {
            result* r = &g_results[i];
            if (r->ok) printf("%-14s %12.2f %-9s %s\n", r->name, r->value, r->unit, r->note);
            else printf("%-14s %12s %-9s %s\n", r->name, "n/a", r->unit, r->note);
        }
    }
    return 0;
}
