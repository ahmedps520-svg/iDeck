// iDeck — file-backed stand-in for POSIX shared memory. See the header.
#include "IDSharedMemoryFallback.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*shm_open_fn)(const char *, int, ...);
typedef int (*shm_unlink_fn)(const char *);

static const char kFilePrefix[] = "shm-";

static char g_dir[PATH_MAX];
static char g_filter[PATH_MAX];
static IDShmFallbackMode g_mode = IDShmFallbackOff;
static shm_open_fn g_real_open;
static shm_unlink_fn g_real_unlink;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_installed;

static atomic_ulong s_images, s_slots, s_patch_failures, s_opens, s_file_opens, s_file_failures;

// "<dir>/shm-<name>" with '/' replaced: shm names are flat, file names are paths.
static int file_path_for(const char *name, char *out, size_t len) {
    int n = snprintf(out, len, "%s/%s", g_dir, kFilePrefix);
    if (n < 0 || (size_t)n >= len) return -1;
    size_t i = (size_t)n;
    for (const char *p = name; *p; p++) {
        if (i + 1 >= len) return -1;
        out[i++] = (*p == '/') ? '_' : *p;
    }
    out[i] = '\0';
    return 0;
}

int id_shm_fallback_open(const char *name, int oflag, unsigned int mode) {
    atomic_fetch_add(&s_opens, 1);
    if (!name) {
        errno = EINVAL;
        return -1;
    }
    if (g_mode != IDShmFallbackAlways && g_real_open) {
        int fd = g_real_open(name, oflag, mode);
        if (fd >= 0 || g_mode == IDShmFallbackOff || (errno != EPERM && errno != EACCES)) return fd;
    }
    char path[PATH_MAX];
    if (!g_dir[0] || file_path_for(name, path, sizeof path) != 0) {
        atomic_fetch_add(&s_file_failures, 1);
        errno = ENAMETOOLONG;
        return -1;
    }
    // Same flags as the shm request (O_CREAT|O_EXCL keeps the collision
    // retry loop in anon_file.c working), plus close-on-exec.
    int flags = (oflag & (O_ACCMODE | O_CREAT | O_EXCL | O_TRUNC)) | O_CLOEXEC;
    int fd = open(path, flags, mode ? (mode_t)mode : (mode_t)0600);
    if (fd < 0) {
        atomic_fetch_add(&s_file_failures, 1);
        return -1;
    }
    atomic_fetch_add(&s_file_opens, 1);
    return fd;
}

int id_shm_fallback_unlink(const char *name) {
    if (!name) {
        errno = EINVAL;
        return -1;
    }
    if (g_mode != IDShmFallbackOff && g_dir[0]) {
        char path[PATH_MAX];
        if (file_path_for(name, path, sizeof path) == 0 && unlink(path) == 0) return 0;
        if (g_mode == IDShmFallbackAlways || !g_real_unlink) return -1;
    }
    if (!g_real_unlink) {
        errno = ENOSYS;
        return -1;
    }
    return g_real_unlink(name);
}

// shm_open is variadic; on arm64 Darwin variadic arguments are passed on the
// stack, so the stand-in must be variadic too to read `mode`.
static int stand_in_shm_open(const char *name, int oflag, ...) {
    unsigned int mode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (unsigned int)va_arg(ap, int);
        va_end(ap);
    }
    return id_shm_fallback_open(name, oflag, mode);
}

static int stand_in_shm_unlink(const char *name) {
    return id_shm_fallback_unlink(name);
}

// Stores `value` in an import slot, making its page writable for the store
// when dyld left it read-only (__DATA_CONST after chained fixups).
static int write_slot(void **slot, void *value) {
    if (*slot == value) return 0;
    const uintptr_t page = (uintptr_t)getpagesize();
    const uintptr_t start = (uintptr_t)slot & ~(page - 1);

    vm_address_t addr = (vm_address_t)start;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;
    if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count,
                     &object) == KERN_SUCCESS &&
        addr <= start) {
        prot = info.protection;
    }
    const int writable = (prot & VM_PROT_WRITE) != 0;
    if (!writable && mprotect((void *)start, page, PROT_READ | PROT_WRITE) != 0) return -1;
    // An aligned pointer store: other threads calling through the slot see
    // either the old or the new target.
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
    if (!writable) {
        int restore = 0;
        if (prot & VM_PROT_READ) restore |= PROT_READ;
        if (prot & VM_PROT_EXECUTE) restore |= PROT_EXEC;
        mprotect((void *)start, page, restore);
    }
    return 0;
}

static void patch_image(const struct mach_header *mh, intptr_t slide) {
    if (!mh || mh->magic != MH_MAGIC_64) return;
    if (g_filter[0]) {
        Dl_info dl;
        if (!dladdr(mh, &dl) || !dl.dli_fname || !strstr(dl.dli_fname, g_filter)) return;
    }
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const uint8_t *cmd = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, SEG_LINKEDIT, sizeof seg->segname) == 0) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)lc;
        }
        cmd += lc->cmdsize;
    }
    if (!linkedit || !symtab || !dysymtab || dysymtab->nindirectsyms == 0) return;

    const uintptr_t base = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    unsigned long patched = 0;
    cmd = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        cmd += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        // __DATA, __DATA_CONST, __DATA_DIRTY, __AUTH, __AUTH_CONST
        if (strncmp(seg->segname, "__DATA", 6) != 0 && strncmp(seg->segname, "__AUTH", 6) != 0) continue;
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            const uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            const size_t slots_in_section = (size_t)(sect->size / sizeof(void *));
            if ((uint64_t)sect->reserved1 + slots_in_section > dysymtab->nindirectsyms) continue;
            void **slots = (void **)((uintptr_t)slide + (uintptr_t)sect->addr);
            const uint32_t *ind = indirect + sect->reserved1;
            for (size_t k = 0; k < slots_in_section; k++) {
                const uint32_t si = ind[k];
                if (si & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                if (si >= symtab->nsyms) continue;
                const uint32_t strx = syms[si].n_un.n_strx;
                if (strx >= symtab->strsize) continue;
                const char *sym = strs + strx;
                void *replacement = NULL;
                if (strcmp(sym, "_shm_open") == 0) {
                    replacement = (void *)stand_in_shm_open;
                } else if (strcmp(sym, "_shm_unlink") == 0) {
                    replacement = (void *)stand_in_shm_unlink;
                }
                if (!replacement) continue;
                if (write_slot(&slots[k], replacement) == 0) {
                    patched++;
                } else {
                    atomic_fetch_add(&s_patch_failures, 1);
                }
            }
        }
    }
    if (patched) {
        atomic_fetch_add(&s_images, 1);
        atomic_fetch_add(&s_slots, patched);
    }
}

static void on_add_image(const struct mach_header *mh, intptr_t slide) {
    pthread_mutex_lock(&g_lock);
    patch_image(mh, slide);
    pthread_mutex_unlock(&g_lock);
}

static void remove_stale_files(void) {
    DIR *d = opendir(g_dir);
    if (!d) return;
    struct dirent *e;
    char path[PATH_MAX];
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, kFilePrefix, sizeof kFilePrefix - 1) != 0) continue;
        if (snprintf(path, sizeof path, "%s/%s", g_dir, e->d_name) < (int)sizeof path) unlink(path);
    }
    closedir(d);
}

int id_shm_fallback_install(const char *directory, const char *image_filter, IDShmFallbackMode mode) {
    pthread_mutex_lock(&g_lock);
    if (g_installed) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    if (!directory || !directory[0] || strlen(directory) >= sizeof g_dir - 64) {
        pthread_mutex_unlock(&g_lock);
        errno = EINVAL;
        return -1;
    }
    struct stat st;
    int bad = 0;
    if (stat(directory, &st) != 0) {
        bad = errno;
    } else if (!S_ISDIR(st.st_mode)) {
        bad = ENOTDIR;
    }
    if (bad) {
        pthread_mutex_unlock(&g_lock);
        errno = bad;
        return -1;
    }
    snprintf(g_dir, sizeof g_dir, "%s", directory);
    snprintf(g_filter, sizeof g_filter, "%s", image_filter ? image_filter : "");
    g_real_open = (shm_open_fn)dlsym(RTLD_DEFAULT, "shm_open");
    g_real_unlink = (shm_unlink_fn)dlsym(RTLD_DEFAULT, "shm_unlink");
    g_mode = mode;
    remove_stale_files();
    g_installed = 1;
    pthread_mutex_unlock(&g_lock);
    // Called right away for every loaded image, then for each new one.
    if (mode != IDShmFallbackOff) _dyld_register_func_for_add_image(on_add_image);
    return 0;
}

void id_shm_fallback_get_stats(IDShmFallbackStats *out) {
    if (!out) return;
    out->images_patched = atomic_load(&s_images);
    out->slots_patched = atomic_load(&s_slots);
    out->patch_failures = atomic_load(&s_patch_failures);
    out->opens = atomic_load(&s_opens);
    out->file_opens = atomic_load(&s_file_opens);
    out->file_failures = atomic_load(&s_file_failures);
}

int id_shm_fallback_selftest(size_t size, char *err, size_t err_len) {
#define FAIL(...)                                          \
    do {                                                   \
        if (err && err_len) snprintf(err, err_len, __VA_ARGS__); \
        goto fail;                                         \
    } while (0)
    const size_t page = (size_t)getpagesize();
    if (size < page) size = page;
    size = (size + page - 1) & ~(page - 1);
    char name[48];
    snprintf(name, sizeof name, "ideck-selftest/%x", arc4random());
    void *a = MAP_FAILED, *b = MAP_FAILED;
    int fd = id_shm_fallback_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) FAIL("open: %s", strerror(errno));
    if (id_shm_fallback_unlink(name) != 0) FAIL("unlink: %s", strerror(errno));
    if (ftruncate(fd, (off_t)size) != 0) FAIL("ftruncate(%zu): %s", size, strerror(errno));
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < size) FAIL("fstat size %lld < %zu", (long long)st.st_size, size);
    a = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (a == MAP_FAILED) FAIL("mmap: %s", strerror(errno));
    b = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (b == MAP_FAILED) FAIL("second mmap: %s", strerror(errno));
    volatile uint32_t *wa = (volatile uint32_t *)a;
    volatile uint32_t *rb = (volatile uint32_t *)b;
    const size_t last = size / sizeof(uint32_t) - 1;
    wa[0] = 0x1DEC0001u;
    wa[last] = 0x1DEC0002u;
    if (rb[0] != 0x1DEC0001u || rb[last] != 0x1DEC0002u) FAIL("the two MAP_SHARED mappings disagree");
    rb[last / 2] = 0x1DEC0003u;
    if (wa[last / 2] != 0x1DEC0003u) FAIL("a write through the second mapping is not visible in the first");
    munmap(a, size);
    munmap(b, size);
    close(fd);
    return 0;
fail:
    if (a != MAP_FAILED) munmap(a, size);
    if (b != MAP_FAILED) munmap(b, size);
    if (fd >= 0) close(fd);
    return -1;
#undef FAIL
}
