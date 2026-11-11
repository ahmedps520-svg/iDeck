// iDeck — file-backed stand-in for POSIX shared memory (Venus blob memory).
//
// UTM's virglrenderer allocates every Venus (Vulkan) blob with
// os_create_anonymous_file(): shm_open("<app group>/<hex>"), shm_unlink(),
// ftruncate(), mmap(MAP_SHARED). The iOS sandbox allows POSIX shared memory
// only under an app group that is in the code signature, and free Apple ID
// signing (Sideloadly, AltStore) drops app groups, so every blob failed and
// Vulkan had to be turned off.
//
// QEMU, virglrenderer and MoltenVK all run inside the iDeck process, so the
// memory does not have to cross a process boundary: an unlinked regular file
// in the app's own tmp/ directory gives the same fd semantics (ftruncate,
// MAP_SHARED, fstat size). This module points the shm_open/shm_unlink
// imports of the embedded frameworks at a stand-in that tries the real call
// first and, when the sandbox refuses it (EPERM/EACCES), opens such a file.
// Only symbol pointers in this app's own frameworks are changed; no system
// code is patched and no sandbox rule is bypassed (the files live in the
// app container, which the sandbox always allows).
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    IDShmFallbackOff = 0,
    /// Real shm_open() first; a file only when the sandbox refuses it.
    IDShmFallbackWhenDenied = 1,
    /// Always a file (tests).
    IDShmFallbackAlways = 2,
} IDShmFallbackMode;

typedef struct {
    unsigned long images_patched;  // images with at least one import pointed at the stand-in
    unsigned long slots_patched;   // import slots changed
    unsigned long patch_failures;  // slots that could not be made writable
    unsigned long opens;           // shm_open calls through the stand-in
    unsigned long file_opens;      // ... answered with a file
    unsigned long file_failures;   // ... where the file could not be created
} IDShmFallbackStats;

/// Installs the stand-in for every image whose path contains `image_filter`
/// (all images when it is empty), now and for images loaded later. Files are
/// created in `directory`, which must exist; stale files from an earlier
/// run are removed. Returns 0, or -1 with errno set. Only the first call
/// installs; later calls return 0 and change nothing.
int id_shm_fallback_install(const char *directory, const char *image_filter, IDShmFallbackMode mode);

void id_shm_fallback_get_stats(IDShmFallbackStats *out);

/// The stand-ins, callable directly (self-checks, tests).
int id_shm_fallback_open(const char *name, int oflag, unsigned int mode);
int id_shm_fallback_unlink(const char *name);

/// Runs the virglrenderer allocation sequence through the stand-in: open,
/// unlink, ftruncate(size), two MAP_SHARED mappings that must see each
/// other's writes. Returns 0, or -1 with a reason in `err`.
int id_shm_fallback_selftest(size_t size, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif
