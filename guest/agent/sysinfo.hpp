// ideck-agent — guest system information (Linux /proc and /sys).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "ideck/json.hpp"

namespace agent {

struct CpuTimes {
    uint64_t busy = 0;
    uint64_t total = 0;
};

// Aggregate and per-CPU jiffies from /proc/stat (index 0 = aggregate).
std::vector<CpuTimes> read_cpu_times();
// Percent busy between two samples, per entry.
std::vector<double> cpu_usage(const std::vector<CpuTimes>& a, const std::vector<CpuTimes>& b);

struct MemInfo {
    uint64_t total_kb = 0;
    uint64_t available_kb = 0;
    uint64_t free_kb = 0;
    uint64_t cached_kb = 0;
    uint64_t swap_total_kb = 0;
    uint64_t swap_free_kb = 0;
};

// Parses /proc/meminfo-formatted text.
MemInfo parse_meminfo(const std::string& text);
MemInfo read_meminfo();

struct FsUsage {
    uint64_t size = 0;
    uint64_t used = 0;
    uint64_t avail = 0;
    bool ok = false;
};
FsUsage fs_usage(const char* path);

// pids whose /proc/<pid>/exe or cmdline matches `needle` (substring).
std::vector<int> find_processes(const std::string& needle);

std::string read_text(const std::string& path, size_t max = 1 << 20);
// Parses an os-release file into {"ID":..,"VERSION_ID":..,"PRETTY_NAME":..}.
ideck::Json parse_os_release(const std::string& text);
// Feature flags from /proc/cpuinfo "Features" line.
std::vector<std::string> parse_cpu_features(const std::string& cpuinfo);

ideck::Json static_info();
ideck::Json dynamic_status(const std::vector<CpuTimes>& prev, std::vector<CpuTimes>& now);

}  // namespace agent
