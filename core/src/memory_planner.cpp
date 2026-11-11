#include "ideck/memory_planner.hpp"

#include <algorithm>

namespace ideck {

namespace {

// Measured/assumed fixed costs, in MiB. These are deliberately conservative
// and are recorded in PERFORMANCE.md; the in-app memory probe refines them.
constexpr uint64_t kAppUiMb = 220;        // SwiftUI, artwork caches, CocoaSpice
constexpr uint64_t kQemuBaseMb = 180;     // QEMU heap, device models, SPICE
constexpr uint64_t kPerCpuMb = 24;        // per-vCPU thread stacks + TCG state
// Headroom against jetsam spikes. Guest RAM is touched lazily and the
// pressure policy (balloon, cache drops) reacts before the limit, so 384 MiB
// is enough; on a 12 GB M5 with a measured 5120 MiB limit this yields a
// 3 GiB guest instead of 2 GiB (too small for Steam).
constexpr uint64_t kSafetyMarginMb = 384;

uint64_t tb_cache_for(uint64_t guest_mb) {
    // QEMU's default code buffer on 64-bit hosts is 1 GiB. Under JIT the
    // cache is touched as it fills, so it grows toward that size; bound it.
    if (guest_mb <= 2048) return 256;
    if (guest_mb <= 4096) return 384;
    return 512;
}

uint64_t gpu_budget_for(uint64_t guest_mb, bool vulkan) {
    if (!vulkan) return 384;
    // Venus allocations (textures, buffers, pipelines) live in host Metal
    // memory and count toward the app footprint. Games at 720p typically
    // need 0.75-1.5 GiB of GPU memory.
    return guest_mb >= 4096 ? 1536 : 768;
}

}  // namespace

const std::vector<uint64_t>& guest_memory_tiers() {
    static const std::vector<uint64_t> tiers = {2048, 3072, 4096, 5120, 6144};
    return tiers;
}

uint64_t estimate_app_limit_mb(uint64_t physical_mb, bool increased_memory_limit) {
    // Public measurements (DISTRIBUTION.md, "Memory limits"): a 12 GB iPhone
    // 17 Pro Max reaches ~6144 MB with the increased-memory-limit
    // entitlement; 16 GB M4 iPads report 5.3-6 GB available on iPadOS 27.
    // Use half of RAM with the entitlement and 3/8 without. The real value
    // always comes from os_proc_available_memory() on device.
    if (physical_mb == 0) return 0;
    double frac = increased_memory_limit ? 0.50 : 0.375;
    return static_cast<uint64_t>(static_cast<double>(physical_mb) * frac);
}

Json MemoryPlan::to_json() const {
    Json j = Json::object();
    j.set("guest_mb", guest_mb);
    j.set("tb_cache_mb", tb_cache_mb);
    j.set("gpu_budget_mb", gpu_budget_mb);
    j.set("hostmem_mb", hostmem_mb);
    j.set("overhead_mb", overhead_mb);
    j.set("limit_mb", limit_mb);
    j.set("fits", fits);
    Json tiers = Json::array();
    for (auto t : allowed_tiers) tiers.push(t);
    j.set("allowed_tiers", std::move(tiers));
    Json n = Json::array();
    for (const auto& s : notes) n.push(s);
    j.set("notes", std::move(n));
    return j;
}

MemoryPlan plan_memory(const MemoryInputs& in) {
    MemoryPlan p;
    uint64_t limit = in.app_limit_mb;
    if (limit == 0) {
        limit = estimate_app_limit_mb(in.physical_mb, in.increased_memory_limit);
        p.notes.push_back("app memory limit unknown; estimated from device RAM");
    }
    p.limit_mb = limit;
    int cpus = in.cpus < 1 ? 1 : in.cpus;
    p.overhead_mb = kAppUiMb + kQemuBaseMb + kPerCpuMb * static_cast<uint64_t>(cpus) + kSafetyMarginMb;

    auto charged_guest = [&](uint64_t guest) { return in.ram_file ? guest / 4 : guest; };
    auto cost = [&](uint64_t guest) {
        return charged_guest(guest) + tb_cache_for(guest) + gpu_budget_for(guest, in.vulkan) + p.overhead_mb;
    };
    // File-backed guest RAM still needs device RAM to run at full speed:
    // at most ~40% of it (8 GB devices: 3 GiB; 12 GB: 4-5 GiB).
    const uint64_t ram_cap = (in.ram_file && in.physical_mb) ? in.physical_mb * 2 / 5 + 64 : UINT64_MAX;

    for (auto tier : guest_memory_tiers()) {
        // 6 GiB is only offered with clear headroom (see product spec).
        if (tier >= 6144 && in.physical_mb < 12288) continue;
        if (tier > ram_cap) continue;
        if (cost(tier) <= limit) p.allowed_tiers.push_back(tier);
    }

    uint64_t chosen = 0;
    if (in.user_guest_mb) {
        bool allowed = std::find(p.allowed_tiers.begin(), p.allowed_tiers.end(), in.user_guest_mb) !=
                       p.allowed_tiers.end();
        if (allowed) {
            chosen = in.user_guest_mb;
        } else {
            p.notes.push_back("requested guest size " + std::to_string(in.user_guest_mb) +
                              " MiB does not fit the memory limit; using the largest that does");
        }
    }
    if (!chosen && !p.allowed_tiers.empty()) {
        // Prefer 4 GiB when it fits: Steam (CEF) plus a game under FEX needs
        // it, and larger tiers raise jetsam risk for little gain at 720p.
        chosen = p.allowed_tiers.back();
        if (chosen > 4096 &&
            std::find(p.allowed_tiers.begin(), p.allowed_tiers.end(), 4096) != p.allowed_tiers.end() &&
            !in.increased_memory_limit) {
            chosen = 4096;
            p.notes.push_back("capped at 4096 MiB without the increased-memory-limit entitlement");
        }
    }
    if (!chosen) {
        chosen = guest_memory_tiers().front();
        p.fits = false;
        p.notes.push_back("even the smallest tier exceeds the estimated limit; expect memory pressure");
    } else {
        p.fits = true;
    }
    p.guest_mb = chosen;
    p.tb_cache_mb = tb_cache_for(chosen);
    p.gpu_budget_mb = gpu_budget_for(chosen, in.vulkan);
    // The hostmem BAR is guest-physical address space for mapping Venus
    // blobs; it is not allocated up front. Kept moderate to limit host VA use.
    p.hostmem_mb = in.vulkan ? (chosen >= 4096 ? 4096 : 2048) : 0;
    return p;
}

const char* pressure_level_name(PressureLevel l) {
    switch (l) {
        case PressureLevel::Normal: return "normal";
        case PressureLevel::Warning: return "warning";
        case PressureLevel::Critical: return "critical";
    }
    return "normal";
}

PressureActions pressure_actions(PressureLevel level, uint64_t guest_mb, uint64_t used_guest_mb) {
    PressureActions a;
    if (level == PressureLevel::Normal) {
        // Return the balloon to the guest.
        a.balloon_target_mb = guest_mb;
        return a;
    }
    a.release_ui_caches = true;
    a.drop_guest_caches = true;
    // Inflate the balloon down to what the guest actually uses plus slack,
    // never below half the configured size.
    uint64_t slack = level == PressureLevel::Warning ? 768 : 256;
    uint64_t floor = guest_mb / 2;
    uint64_t target = used_guest_mb + slack;
    if (target < floor) target = floor;
    if (target > guest_mb) target = guest_mb;
    a.balloon_target_mb = target;
    if (level == PressureLevel::Critical) {
        a.flush_disks = true;
        a.notify_user = true;
        a.throttle_downloads = true;
    }
    return a;
}

}  // namespace ideck
