// iDeck core — adaptive guest memory planning.
//
// iPadOS kills an app (jetsam) when its physical footprint passes a per-app
// limit that depends on device RAM and entitlements. Everything iDeck runs
// counts against that one limit: guest RAM the guest has touched, QEMU's TCG
// translation cache, virglrenderer/MoltenVK GPU allocations (unified memory),
// and the app UI. The planner picks the largest guest RAM tier that leaves
// room for the rest, and decides how to react to memory pressure.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "ideck/json.hpp"

namespace ideck {

struct MemoryInputs {
    uint64_t physical_mb = 0;     // total device RAM
    // Footprint headroom reported by os_proc_available_memory() plus the
    // app's current footprint, i.e. the effective jetsam limit. 0 = unknown.
    uint64_t app_limit_mb = 0;
    uint64_t current_footprint_mb = 0;
    bool increased_memory_limit = false;  // entitlement granted
    uint64_t user_guest_mb = 0;           // explicit choice in Advanced; 0 = auto
    int cpus = 4;
    bool vulkan = true;
    // Guest RAM is a shared file mapping (Settings.ramInFile). iOS can write
    // those pages back to the file and drop them, and does not charge them
    // to the footprint like anonymous memory: on an M5 iPad the footprint
    // stayed near 1 GiB with 780 MiB of guest RAM in use. The planner then
    // charges a quarter of guest RAM to the limit, and instead caps guest RAM
    // by device RAM, since paging guest memory to flash is slow.
    bool ram_file = false;
};

struct MemoryPlan {
    uint64_t guest_mb = 0;
    uint64_t tb_cache_mb = 0;     // -accel tcg,tb-size=
    uint64_t gpu_budget_mb = 0;   // reserved for host-side GPU allocations
    uint64_t hostmem_mb = 0;      // virtio-gpu hostmem window (address space)
    uint64_t overhead_mb = 0;     // QEMU + app + safety margin
    uint64_t limit_mb = 0;        // the limit the plan was fitted against
    bool fits = false;            // false: even the smallest tier is over budget
    std::vector<uint64_t> allowed_tiers;  // tiers that fit, for the settings UI
    std::vector<std::string> notes;

    Json to_json() const;
};

// Tiers the product supports, in MiB.
const std::vector<uint64_t>& guest_memory_tiers();

// Best estimate of the jetsam limit when the OS value is unavailable
// (simulator, tests): a conservative fraction of physical RAM.
uint64_t estimate_app_limit_mb(uint64_t physical_mb, bool increased_memory_limit);

MemoryPlan plan_memory(const MemoryInputs& in);

enum class PressureLevel { Normal, Warning, Critical };

struct PressureActions {
    bool drop_guest_caches = false;   // ask agent: sync + drop_caches
    uint64_t balloon_target_mb = 0;   // 0 = leave balloon alone; else guest size
    bool release_ui_caches = false;   // artwork, thumbnails
    bool flush_disks = false;         // guarantee persistence before a kill
    bool notify_user = false;
    bool throttle_downloads = false;
};

// `guest_mb` is the configured guest size, `used_guest_mb` what the guest
// reports as in use (MemTotal - MemAvailable).
PressureActions pressure_actions(PressureLevel level, uint64_t guest_mb, uint64_t used_guest_mb);

const char* pressure_level_name(PressureLevel l);

}  // namespace ideck
