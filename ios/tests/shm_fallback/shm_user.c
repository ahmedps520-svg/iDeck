// Test library: allocates memory the way UTM's virglrenderer does on Apple
// platforms (src/mesa/util/anon_file.c, os_create_anonymous_file): a POSIX
// shared memory object named "<APP_SANDBOX_GROUP_ID>/<slot><nonce>", retried
// on EEXIST, unlinked at once, then sized with ftruncate. It is a separate
// image so the test can check that only its imports are redirected.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

__attribute__((visibility("default"))) int user_create_anonymous_file(off_t size) {
    const char *group = getenv("APP_SANDBOX_GROUP_ID");
    if (group && !group[0]) group = NULL;
    const unsigned int nonce = arc4random() >> 4;
    int fd = -1;
    for (unsigned int slot = 0; slot < 16; slot++) {
        char name[64];
        if (group) {
            snprintf(name, sizeof name, "%s/%x%x", group, slot, nonce);
        } else {
            snprintf(name, sizeof name, "/vkr-host-mem-%d-%x-%x", getpid(), nonce, slot);
        }
        fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd >= 0) {
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            shm_unlink(name);
            break;
        }
        if (errno != EEXIST) break;
    }
    if (fd < 0) return -1;
    if (ftruncate(fd, size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// The same name twice: the second O_EXCL open must fail with EEXIST, which
// is what anon_file.c's retry loop relies on.
__attribute__((visibility("default"))) int user_exclusive_twice(const char *name) {
    int a = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (a < 0) return -1;
    int b = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    int err = errno;
    shm_unlink(name);
    close(a);
    if (b >= 0) {
        close(b);
        return -2;
    }
    return err == EEXIST ? 0 : -3;
}
