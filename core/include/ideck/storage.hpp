// iDeck core — game storage policy.
//
// The game library lives on a sparse raw disk image ("data.img", whole-disk
// ext4 mounted at /home in the guest). It starts small and grows: the host
// enlarges the file, QMP block_resize tells the guest, and the agent runs
// resize2fs online. This module decides when and by how much.
#pragma once

#include <cstdint>
#include <string>

#include "ideck/json.hpp"

namespace ideck {

struct StorageInputs {
    uint64_t host_free = 0;        // bytes free on the iPad volume
    uint64_t disk_size = 0;        // logical size of data.img
    uint64_t disk_allocated = 0;   // bytes actually allocated
    uint64_t fs_size = 0;          // guest filesystem size
    uint64_t fs_used = 0;          // guest filesystem used
    uint64_t host_reserve = 8ull << 30;   // never let iPadOS drop below this
    uint64_t max_disk = 200ull << 30;     // hard cap for the image
    uint64_t min_step = 16ull << 30;      // smallest growth increment
    double grow_threshold = 0.85;         // grow when the fs is this full
};

struct StorageDecision {
    bool grow = false;
    uint64_t new_size = 0;
    bool host_low = false;       // warn the user: iPad storage nearly full
    bool guest_full = false;     // cannot grow further; ask to free space
    std::string reason;
    Json to_json() const;
};

StorageDecision decide_storage(const StorageInputs& in);

// Initial data disk size at install: enough for Steam + a small game, but
// far below the device capacity (it grows on demand).
uint64_t initial_data_disk_size(uint64_t host_free);

}  // namespace ideck
