// Tests IDSharedMemoryFallback on macOS (CI: .github/workflows/ci.yml).
//
//   shm_fallback_test always <libshm_user.dylib>
//       every shm_open of the library becomes a file
//   sandbox-exec -p '(version 1)(allow default)(deny ipc-posix-shm*)' \
//       shm_fallback_test denied <libshm_user.dylib>
//       the sandbox refuses POSIX shared memory, as iOS does without an app
//       group; the library's allocations must still succeed through files
//
// Exit status 0 = pass, 1 = fail, 2 = usage. Prints SKIP (status 0) when the
// sandbox did not refuse shm_open, so the denied case could not be tested.
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "IDSharedMemoryFallback.h"

static int failures;

#define CHECK(cond, ...)                         \
    do {                                         \
        if (!(cond)) {                           \
            printf("FAIL %s:%d: ", __FILE__, __LINE__); \
            printf(__VA_ARGS__);                 \
            printf("\n");                        \
            failures++;                          \
        }                                        \
    } while (0)

static int count_files(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] != '.') n++;
    }
    closedir(d);
    return n;
}

static void check_mapping(int fd, size_t size, const char *what) {
    struct stat st;
    CHECK(fstat(fd, &st) == 0 && (size_t)st.st_size == size, "%s: fstat size %lld, want %zu", what,
          (long long)st.st_size, size);
    void *a = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    void *b = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    CHECK(a != MAP_FAILED && b != MAP_FAILED, "%s: mmap: %s", what, strerror(errno));
    if (a == MAP_FAILED || b == MAP_FAILED) return;
    volatile uint64_t *wa = (volatile uint64_t *)a;
    volatile uint64_t *rb = (volatile uint64_t *)b;
    size_t last = size / sizeof(uint64_t) - 1;
    for (size_t i = 0; i <= last; i += 4096) wa[i] = 0xC0FFEE00u + i;
    wa[last] = 0xFEEDu;
    int same = rb[last] == 0xFEEDu;
    for (size_t i = 0; i <= last; i += 4096) same = same && rb[i] == 0xC0FFEE00u + i;
    CHECK(same, "%s: MAP_SHARED mappings disagree", what);
    munmap(a, size);
    munmap(b, size);
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "always") != 0 && strcmp(argv[1], "denied") != 0)) {
        fprintf(stderr, "usage: %s always|denied <libshm_user.dylib>\n", argv[0]);
        return 2;
    }
    const int denied = strcmp(argv[1], "denied") == 0;

    char dir[] = "/tmp/ideck-shm-test-XXXXXX";
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    setenv("APP_SANDBOX_GROUP_ID", "group.com.ideck.app", 1);

    if (denied) {
        // This executable is not patched (image filter), so this is the real
        // call: it must be refused for the case to mean anything.
        int fd = shm_open("group.com.ideck.app/probe", O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd >= 0) {
            shm_unlink("group.com.ideck.app/probe");
            close(fd);
            printf("SKIP: the sandbox did not refuse shm_open; run this case under sandbox-exec\n");
            return 0;
        }
        printf("real shm_open refused as on iOS: %s\n", strerror(errno));
    }

    CHECK(id_shm_fallback_install(dir, "libshm_user", denied ? IDShmFallbackWhenDenied : IDShmFallbackAlways) == 0,
          "install: %s", strerror(errno));
    IDShmFallbackStats st;
    id_shm_fallback_get_stats(&st);
    CHECK(st.images_patched == 0, "nothing matching the filter is loaded yet, but %lu images were patched",
          st.images_patched);

    // Images loaded after install are patched by the dyld callback.
    void *lib = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    CHECK(lib != NULL, "dlopen %s: %s", argv[2], dlerror());
    if (!lib) return 1;
    int (*create)(off_t) = (int (*)(off_t))dlsym(lib, "user_create_anonymous_file");
    int (*twice)(const char *) = (int (*)(const char *))dlsym(lib, "user_exclusive_twice");
    CHECK(create && twice, "dlsym");
    if (!create || !twice) return 1;

    id_shm_fallback_get_stats(&st);
    CHECK(st.images_patched == 1, "images patched %lu, want 1 (only libshm_user)", st.images_patched);
    CHECK(st.slots_patched >= 2, "slots patched %lu, want shm_open and shm_unlink", st.slots_patched);
    CHECK(st.patch_failures == 0, "patch failures %lu", st.patch_failures);

    // The allocation sequence of anon_file.c, several sizes like Venus uses.
    const size_t sizes[] = {16384, 1 << 20, 64u << 20};
    int fds[3];
    for (int i = 0; i < 3; i++) {
        fds[i] = create((off_t)sizes[i]);
        CHECK(fds[i] >= 0, "allocation %d (%zu bytes) failed: %s", i, sizes[i], strerror(errno));
        if (fds[i] >= 0) check_mapping(fds[i], sizes[i], "allocation");
    }
    CHECK(count_files(dir) == 0, "%d files left in %s; the names must be unlinked right away", count_files(dir), dir);
    id_shm_fallback_get_stats(&st);
    CHECK(st.file_opens == 3, "file opens %lu, want 3", st.file_opens);
    CHECK(st.file_failures == 0, "file failures %lu", st.file_failures);

    CHECK(twice("group.com.ideck.app/dup") == 0, "a second O_EXCL open of the same name must fail with EEXIST");
    CHECK(count_files(dir) == 0, "the duplicate-name file was not removed");

    char err[256] = "";
    CHECK(id_shm_fallback_selftest(1 << 20, err, sizeof err) == 0, "selftest: %s", err);

    for (int i = 0; i < 3; i++) {
        if (fds[i] >= 0) close(fds[i]);
    }
    rmdir(dir);
    id_shm_fallback_get_stats(&st);
    printf("%s mode: %lu image(s), %lu slot(s) patched; %lu shm_open calls, %lu answered with files\n", argv[1],
           st.images_patched, st.slots_patched, st.opens, st.file_opens);
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
