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
// The first line of a kernel or text log containing `needle`, without the
// "<level>[timestamp] " prefix; "" if none.
std::string find_log_line(const std::string& log, const std::string& needle);
std::string trimmed(std::string s);

ideck::Json static_info();
ideck::Json dynamic_status(const std::vector<CpuTimes>& prev, std::vector<CpuTimes>& now);

struct ProcStat {
    std::string comm;
    uint64_t ticks = 0;      // utime + stime, in clock ticks
    int nice = 0;
    int threads = 0;
    uint64_t rss_pages = 0;
};
// Parses one /proc/<pid>/stat line. The command name may contain spaces and
// parentheses, so it is the text between the first '(' and the last ')'.
bool parse_proc_stat(const std::string& stat, ProcStat& out);
// The value of "Key:\tvalue" in /proc/<pid>/status text; "" if absent.
std::string status_value(const std::string& status, const std::string& key);
// Processes by CPU use over `interval_ms` (percent of one vCPU), each with
// its nice value, thread count, resident size and allowed CPUs, plus totals
// per command name. Blocks for the interval.
ideck::Json top_processes(int interval_ms, size_t limit);

// Compares an ideck-fpcheck result (bench/fpcheck.c) with one recorded on
// real hardware. "match" is true when every instruction pattern and the
// mixed sequences produced the same register values; exception flags are
// reported separately ("flags_match"). Differing pattern names are listed,
// at most `limit` of each kind.
ideck::Json fpcheck_compare(const ideck::Json& result, const ideck::Json& reference, size_t limit = 24);

}  // namespace agent
