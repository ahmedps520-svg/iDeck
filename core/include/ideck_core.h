/*
 * iDeck core — C ABI for the Swift app.
 *
 * Most calls are JSON-in / JSON-out through ideck_call() so the Swift side
 * needs no struct bridging. Hot paths (hashing, sparse image expansion,
 * controller packets) have dedicated functions.
 *
 * Every char* returned by this library must be released with ideck_free().
 */
#ifndef IDECK_CORE_H
#define IDECK_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char* ideck_core_version(void);

/*
 * Methods (args -> result):
 *   memory.plan        MemoryInputs        -> MemoryPlan
 *   memory.pressure    {level,guest_mb,used_guest_mb} -> actions
 *   qemu.args          VmConfig            -> {"argv":[...],"warnings":[...]}
 *   manifest.validate  {"text":"..."}      -> normalised manifest
 *   journal.load       {"path"}            -> journal (created if missing)
 *   journal.begin|complete|skip|fail {"path","id"[,"error"]} -> journal
 *   journal.reset_from {"path","id"}       -> journal
 *   storage.decide     StorageInputs       -> StorageDecision
 *   storage.initial_size {"host_free"}     -> {"size"}
 *   storage.create_sparse {"path","size"}  -> {}
 *   storage.grow       {"path","size"}     -> {}
 *   storage.clone      {"src","dst"}       -> {"cow":bool}
 *   storage.usage      {"path"}            -> {"size","allocated","free"}
 *   file.sha256        {"path"}            -> {"sha256"}
 *   control.request    {"id","op","args"}  -> {"line"}
 *   control.parse      {"line"}            -> message
 *   compat.lookup      {"db","appid"}      -> entry | null
 *
 * Returns {"ok":true,"result":...} or {"ok":false,"error":"..."}.
 */
char* ideck_call(const char* method, const char* args_json);
void ideck_free(char* p);

/* Streaming SHA-256. */
typedef struct ideck_sha256 ideck_sha256;
ideck_sha256* ideck_sha256_new(void);
void ideck_sha256_update(ideck_sha256* h, const void* data, size_t len);
/* Writes 64 hex chars + NUL into out (>= 65 bytes) and frees h. */
void ideck_sha256_finish(ideck_sha256* h, char* out);

/* Sparse file writer for expanding disk images. */
typedef struct ideck_sparse ideck_sparse;
ideck_sparse* ideck_sparse_open(const char* path);
int ideck_sparse_write(ideck_sparse* w, const void* data, size_t len); /* 1 ok, 0 fail */
/* Finishes, closes and frees. Returns 1 on success. */
int ideck_sparse_finish(ideck_sparse* w, uint64_t* bytes_skipped);
void ideck_sparse_abort(ideck_sparse* w);

/* Controller packets (see protocol.hpp). */
typedef struct {
    uint8_t type;   /* 1 state, 2 connect, 3 disconnect, 5 keepalive */
    uint8_t pad;
    uint8_t kind;   /* 0 generic, 1 xbox, 2 playstation, 3 nintendo */
    uint16_t seq;
    uint32_t buttons;
    float lx, ly, rx, ry; /* -1..1, +y up */
    float lt, rt;         /* 0..1 */
} ideck_pad_state;

typedef struct {
    uint8_t pad;
    uint16_t strong, weak; /* 0..65535 */
    uint16_t duration_ms;
} ideck_rumble;

void ideck_input_encode(const ideck_pad_state* s, uint8_t out[32]);

/* Incremental decoder for guest -> host packets (rumble). */
typedef struct ideck_input_decoder ideck_input_decoder;
ideck_input_decoder* ideck_input_decoder_new(void);
/* Feeds bytes; writes up to max rumble events, returns how many. */
size_t ideck_input_decoder_feed(ideck_input_decoder* d, const uint8_t* data, size_t len,
                                ideck_rumble* out, size_t max);
void ideck_input_decoder_free(ideck_input_decoder* d);

/* Line framer for the control channel. */
typedef struct ideck_framer ideck_framer;
ideck_framer* ideck_framer_new(void);
/* Feeds bytes; returns a JSON array of complete lines (free with ideck_free). */
char* ideck_framer_feed(ideck_framer* f, const char* data, size_t len);
void ideck_framer_free(ideck_framer* f);

#ifdef __cplusplus
}
#endif

#endif /* IDECK_CORE_H */
