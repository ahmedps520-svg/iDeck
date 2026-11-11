#include "ideck/storage.hpp"

#include <algorithm>

namespace ideck {

namespace {
constexpr uint64_t kGiB = 1ull << 30;
constexpr uint64_t kAlign = 1ull << 20;  // keep sizes MiB-aligned

uint64_t align_down(uint64_t v) { return v / kAlign * kAlign; }
}  // namespace

Json StorageDecision::to_json() const {
    Json j = Json::object();
    j.set("grow", grow);
    j.set("new_size", new_size);
    j.set("host_low", host_low);
    j.set("guest_full", guest_full);
    j.set("reason", reason);
    return j;
}

StorageDecision decide_storage(const StorageInputs& in) {
    StorageDecision d;
    d.new_size = in.disk_size;
    d.host_low = in.host_free < in.host_reserve;

    if (in.fs_size == 0) {
        d.reason = "guest filesystem size unknown";
        return d;
    }
    double usage = static_cast<double>(in.fs_used) / static_cast<double>(in.fs_size);
    if (usage < in.grow_threshold) {
        d.reason = "enough free space in the game library";
        return d;
    }
    if (in.disk_size >= in.max_disk) {
        d.guest_full = true;
        d.reason = "game library reached its maximum size";
        return d;
    }
    // Grow by 25% of the current size, at least min_step, capped at max.
    uint64_t step = std::max(in.min_step, in.disk_size / 4);
    uint64_t target = std::min(in.max_disk, in.disk_size + step);
    uint64_t added = target - in.disk_size;
    // New logical capacity must be backable by real free space beyond the
    // reserve, otherwise the guest could write the iPad completely full.
    uint64_t spare = in.host_free > in.host_reserve ? in.host_free - in.host_reserve : 0;
    if (added > spare) {
        added = align_down(spare);
        target = in.disk_size + added;
    }
    if (added < kGiB) {
        d.guest_full = true;
        d.reason = "not enough free iPad storage to enlarge the game library";
        return d;
    }
    d.grow = true;
    d.new_size = align_down(target);
    d.reason = "game library is " + std::to_string(static_cast<int>(usage * 100)) + "% full";
    return d;
}

uint64_t initial_data_disk_size(uint64_t host_free) {
    // 24 GiB fits the Steam client, runtimes and a mid-size game. On a
    // nearly full iPad, start smaller (min 8 GiB) and grow later.
    uint64_t want = 24 * kGiB;
    uint64_t reserve = 8 * kGiB;
    uint64_t spare = host_free > reserve ? host_free - reserve : 0;
    uint64_t size = std::min(want, spare);
    if (size < 8 * kGiB) size = 8 * kGiB;
    return align_down(size);
}

}  // namespace ideck
