#include "sysinfo.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <thread>

#if defined(__linux__)
#include <dirent.h>
#include <sys/klog.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <unistd.h>
#endif

namespace agent {

using ideck::Json;

std::string find_log_line(const std::string& log, const std::string& needle) {
    size_t at = log.find(needle);
    if (at == std::string::npos) return {};
    size_t begin = log.rfind('\n', at);
    begin = begin == std::string::npos ? 0 : begin + 1;
    size_t end = log.find('\n', at);
    std::string line = log.substr(begin, end == std::string::npos ? std::string::npos : end - begin);
    // Drop the "<6>[    0.000000] " prefix of kernel ring-buffer records.
    if (!line.empty() && line[0] == '<') {
        size_t gt = line.find('>');
        if (gt != std::string::npos) line.erase(0, gt + 1);
    }
    if (!line.empty() && line[0] == '[') {
        size_t rb = line.find("] ");
        if (rb != std::string::npos) line.erase(0, rb + 2);
    }
    return line;
}

std::string trimmed(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == ' ' || s.back() == '\0')) s.pop_back();
    return s;
}

std::string read_text(const std::string& path, size_t max) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return {};
    std::string out;
    char buf[4096];
    while (out.size() < max) {
        size_t n = std::fread(buf, 1, sizeof(buf), f);
        if (n == 0) break;
        out.append(buf, n);
    }
    std::fclose(f);
    if (out.size() > max) out.resize(max);
    return out;
}

std::vector<CpuTimes> read_cpu_times() {
    std::vector<CpuTimes> out;
    std::istringstream in(read_text("/proc/stat"));
    std::string line;
    while (std::getline(in, line)) {
        if (line.compare(0, 3, "cpu") != 0) break;
        std::istringstream ls(line);
        std::string label;
        ls >> label;
        uint64_t v[10] = {0};
        for (auto& x : v) ls >> x;
        // user nice system idle iowait irq softirq steal guest guest_nice
        uint64_t idle = v[3] + v[4];
        uint64_t total = 0;
        for (int i = 0; i < 8; ++i) total += v[i];
        out.push_back({total - idle, total});
    }
    return out;
}

std::vector<double> cpu_usage(const std::vector<CpuTimes>& a, const std::vector<CpuTimes>& b) {
    std::vector<double> out;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        uint64_t dt = b[i].total - a[i].total;
        uint64_t db = b[i].busy - a[i].busy;
        out.push_back(dt ? 100.0 * static_cast<double>(db) / static_cast<double>(dt) : 0.0);
    }
    return out;
}

MemInfo parse_meminfo(const std::string& text) {
    MemInfo m;
    std::istringstream in(text);
    std::string key;
    uint64_t value = 0;
    std::string unit;
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream ls(line);
        if (!(ls >> key >> value)) continue;
        if (key == "MemTotal:") m.total_kb = value;
        else if (key == "MemAvailable:") m.available_kb = value;
        else if (key == "MemFree:") m.free_kb = value;
        else if (key == "Cached:") m.cached_kb = value;
        else if (key == "SwapTotal:") m.swap_total_kb = value;
        else if (key == "SwapFree:") m.swap_free_kb = value;
    }
    return m;
}

MemInfo read_meminfo() { return parse_meminfo(read_text("/proc/meminfo")); }

FsUsage fs_usage(const char* path) {
    FsUsage u;
#if defined(__linux__)
    struct statvfs s;
    if (statvfs(path, &s) == 0) {
        u.size = static_cast<uint64_t>(s.f_blocks) * s.f_frsize;
        u.avail = static_cast<uint64_t>(s.f_bavail) * s.f_frsize;
        u.used = u.size - static_cast<uint64_t>(s.f_bfree) * s.f_frsize;
        u.ok = true;
    }
#else
    (void)path;
#endif
    return u;
}

std::vector<int> find_processes(const std::string& needle) {
    std::vector<int> pids;
#if defined(__linux__)
    DIR* d = opendir("/proc");
    if (!d) return pids;
    while (dirent* e = readdir(d)) {
        char* end = nullptr;
        long pid = std::strtol(e->d_name, &end, 10);
        if (!end || *end || pid <= 0) continue;
        std::string cmd = read_text("/proc/" + std::string(e->d_name) + "/cmdline", 4096);
        // argv[0] only: the first NUL-terminated string.
        std::string argv0 = cmd.substr(0, cmd.find('\0'));
        if (argv0.find(needle) != std::string::npos) pids.push_back(static_cast<int>(pid));
    }
    closedir(d);
#else
    (void)needle;
#endif
    return pids;
}

Json parse_os_release(const std::string& text) {
    Json j = Json::object();
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        size_t eq = line.find('=');
        if (eq == std::string::npos || line[0] == '#') continue;
        std::string k = line.substr(0, eq);
        std::string v = line.substr(eq + 1);
        if (v.size() >= 2 && (v.front() == '"' || v.front() == '\'') && v.back() == v.front()) {
            v = v.substr(1, v.size() - 2);
        }
        if (k == "ID" || k == "VERSION_ID" || k == "PRETTY_NAME" || k == "VERSION_CODENAME") j.set(k, v);
    }
    return j;
}

std::vector<std::string> parse_cpu_features(const std::string& cpuinfo) {
    std::vector<std::string> out;
    std::istringstream in(cpuinfo);
    std::string line;
    while (std::getline(in, line)) {
        if (line.compare(0, 8, "Features") != 0) continue;
        size_t colon = line.find(':');
        if (colon == std::string::npos) continue;
        std::istringstream fs(line.substr(colon + 1));
        std::string f;
        while (fs >> f) out.push_back(f);
        break;  // first CPU is representative
    }
    return out;
}

Json static_info() {
    Json j = Json::object();
#if defined(__linux__)
    struct utsname u;
    if (uname(&u) == 0) {
        j.set("kernel", std::string(u.release));
        j.set("machine", std::string(u.machine));
    }
    j.set("page_size", static_cast<long long>(sysconf(_SC_PAGESIZE)));
    j.set("cpus", static_cast<long long>(sysconf(_SC_NPROCESSORS_ONLN)));
    j.set("cmdline", trimmed(read_text("/proc/cmdline", 4096)));
    // Whether the kernel unmaps itself from user space (KPTI). Under TCG each
    // switch costs a full soft-TLB flush, and on neoverse-n1 KASLR forces it
    // on even with mitigations=off; the meltdown sysfs file does not show
    // this ("Not affected"), the boot message does.
    int size = klogctl(10 /* SYSLOG_ACTION_SIZE_BUFFER */, nullptr, 0);
    if (size > 0) {
        std::string buf(static_cast<size_t>(size), '\0');
        int n = klogctl(3 /* SYSLOG_ACTION_READ_ALL */, &buf[0], size);
        if (n > 0) {
            buf.resize(static_cast<size_t>(n));
            j.set("kpti", find_log_line(buf, "kernel page table isolation"));
        }
    }
#endif
    j.set("os", parse_os_release(read_text("/etc/os-release")));
    MemInfo m = read_meminfo();
    j.set("mem_total_kb", m.total_kb);
    Json feats = Json::array();
    for (const auto& f : parse_cpu_features(read_text("/proc/cpuinfo"))) feats.push(f);
    j.set("cpu_features", std::move(feats));
    std::string runtime = read_text("/usr/lib/ideck/runtime-version", 128);
    while (!runtime.empty() && (runtime.back() == '\n' || runtime.back() == ' ')) runtime.pop_back();
    j.set("runtime_version", runtime);
    return j;
}

Json dynamic_status(const std::vector<CpuTimes>& prev, std::vector<CpuTimes>& now) {
    Json j = Json::object();
    now = read_cpu_times();
    auto usage = cpu_usage(prev, now);
    if (!usage.empty()) {
        j.set("cpu_percent", usage[0]);
        Json per = Json::array();
        for (size_t i = 1; i < usage.size(); ++i) per.push(usage[i]);
        j.set("cpu_per_core", std::move(per));
    }
    MemInfo m = read_meminfo();
    j.set("mem_total_kb", m.total_kb);
    j.set("mem_available_kb", m.available_kb);
    j.set("mem_used_kb", m.total_kb > m.available_kb ? m.total_kb - m.available_kb : 0);
    j.set("swap_used_kb", m.swap_total_kb - m.swap_free_kb);
    std::string load = read_text("/proc/loadavg", 128);
    j.set("loadavg", load.substr(0, load.find(' ')));
    std::string up = read_text("/proc/uptime", 128);
    j.set("uptime_s", std::atof(up.c_str()));
    FsUsage root = fs_usage("/");
    FsUsage home = fs_usage("/home");
    Json disks = Json::object();
    if (root.ok) {
        Json r = Json::object();
        r.set("size", root.size);
        r.set("used", root.used);
        r.set("avail", root.avail);
        disks.set("system", std::move(r));
    }
    if (home.ok) {
        Json h = Json::object();
        h.set("size", home.size);
        h.set("used", home.used);
        h.set("avail", home.avail);
        disks.set("library", std::move(h));
    }
    j.set("disks", std::move(disks));
    j.set("steam_running", !find_processes("steamrtarm64/steam").empty() || !find_processes("/steam").empty());
    return j;
}

bool parse_proc_stat(const std::string& stat, ProcStat& out) {
    size_t open = stat.find('(');
    size_t close = stat.rfind(')');
    if (open == std::string::npos || close == std::string::npos || close < open || close + 2 > stat.size()) {
        return false;
    }
    out.comm = stat.substr(open + 1, close - open - 1);
    std::istringstream rest(stat.substr(close + 2));
    std::vector<std::string> f;  // f[0] is field 3 (state), so field N is f[N - 3]
    for (std::string w; rest >> w;) f.push_back(w);
    if (f.size() < 22) return false;
    out.ticks = std::strtoull(f[11].c_str(), nullptr, 10) + std::strtoull(f[12].c_str(), nullptr, 10);
    out.nice = std::atoi(f[16].c_str());
    out.threads = std::atoi(f[17].c_str());
    out.rss_pages = std::strtoull(f[21].c_str(), nullptr, 10);
    return true;
}

std::string status_value(const std::string& status, const std::string& key) {
    const std::string k = key + ":";
    for (size_t at = status.find(k); at != std::string::npos; at = status.find(k, at + 1)) {
        if (at != 0 && status[at - 1] != '\n') continue;
        size_t v = status.find_first_not_of(" \t", at + k.size());
        size_t end = status.find('\n', at);
        if (v == std::string::npos || (end != std::string::npos && v > end)) return {};
        return status.substr(v, end == std::string::npos ? std::string::npos : end - v);
    }
    return {};
}

Json top_processes(int interval_ms, size_t limit) {
    Json r = Json::object();
#if defined(__linux__)
    auto sample = [] {
        std::map<int, ProcStat> m;
        DIR* d = opendir("/proc");
        if (!d) return m;
        while (dirent* e = readdir(d)) {
            char* end = nullptr;
            long pid = std::strtol(e->d_name, &end, 10);
            if (!end || *end || pid <= 0) continue;
            ProcStat st;
            if (parse_proc_stat(read_text("/proc/" + std::string(e->d_name) + "/stat", 4096), st)) {
                m[static_cast<int>(pid)] = st;
            }
        }
        closedir(d);
        return m;
    };
    auto cpu_a = read_cpu_times();
    auto a = sample();
    std::this_thread::sleep_for(std::chrono::milliseconds(interval_ms));
    auto cpu_b = read_cpu_times();
    auto b = sample();
    const double hz = static_cast<double>(sysconf(_SC_CLK_TCK));
    const double page_mb = static_cast<double>(sysconf(_SC_PAGESIZE)) / (1024.0 * 1024.0);
    const double secs = interval_ms / 1000.0;
    auto round1 = [](double x) { return std::round(x * 10.0) / 10.0; };

    struct Row {
        int pid;
        double cpu;
        const ProcStat* st;
    };
    std::vector<Row> rows;
    struct Group {
        double cpu = 0;
        int processes = 0;
        uint64_t rss_pages = 0;  // RSS counts shared pages in every process
    };
    std::map<std::string, Group> by_comm;
    for (const auto& [pid, st] : b) {
        auto it = a.find(pid);
        // A process that started during the interval counts from zero.
        uint64_t d = (it != a.end() && st.ticks >= it->second.ticks) ? st.ticks - it->second.ticks : 0;
        double cpu = hz > 0 ? 100.0 * static_cast<double>(d) / (hz * secs) : 0.0;
        rows.push_back({pid, cpu, &st});
        auto& g = by_comm[st.comm];
        g.cpu += cpu;
        g.processes += 1;
        g.rss_pages += st.rss_pages;
    }
    std::sort(rows.begin(), rows.end(), [](const Row& x, const Row& y) { return x.cpu > y.cpu; });

    Json procs = Json::array();
    for (size_t i = 0; i < rows.size() && i < limit; ++i) {
        const Row& row = rows[i];
        std::string status = read_text("/proc/" + std::to_string(row.pid) + "/status", 8192);
        Json p = Json::object();
        p.set("pid", row.pid);
        p.set("comm", row.st->comm);
        p.set("cpu", round1(row.cpu));
        p.set("nice", row.st->nice);
        p.set("threads", row.st->threads);
        p.set("rss_mb", round1(static_cast<double>(row.st->rss_pages) * page_mb));
        p.set("cpus", status_value(status, "Cpus_allowed_list"));
        procs.push(std::move(p));
    }
    std::vector<std::pair<std::string, Group>> groups(by_comm.begin(), by_comm.end());
    std::sort(groups.begin(), groups.end(), [](const auto& x, const auto& y) { return x.second.cpu > y.second.cpu; });
    Json g = Json::array();
    for (size_t i = 0; i < groups.size() && i < 10; ++i) {
        Json e = Json::object();
        e.set("comm", groups[i].first);
        e.set("cpu", round1(groups[i].second.cpu));
        e.set("processes", groups[i].second.processes);
        e.set("rss_mb", round1(static_cast<double>(groups[i].second.rss_pages) * page_mb));
        g.push(std::move(e));
    }
    auto total = cpu_usage(cpu_a, cpu_b);
    r.set("interval_ms", interval_ms);
    r.set("online_cpus", trimmed(read_text("/sys/devices/system/cpu/online", 64)));
    if (!total.empty()) r.set("cpu_percent", round1(total[0]));
    r.set("processes", std::move(procs));
    r.set("by_command", std::move(g));
#else
    (void)interval_ms;
    (void)limit;
#endif
    return r;
}

Json fpcheck_compare(const Json& result, const Json& reference, size_t limit) {
    Json out = Json::object();
    Json values = Json::array(), flags = Json::array(), missing = Json::array();
    size_t compared = 0, nvalues = 0, nflags = 0, nmissing = 0;
    const Json& have = result["patterns"];
    const Json& want = reference["patterns"];
    auto note = [limit](Json& list, size_t& n, const std::string& name) {
        if (n++ < limit) list.push(name);
    };
    if (want.is_object()) {
        for (const auto& kv : want.members()) {
            const Json* mine = have.is_object() ? have.find(kv.first) : nullptr;
            if (!mine || !mine->is_array() || mine->size() != 2 || kv.second.size() != 2) {
                note(missing, nmissing, kv.first);
                continue;
            }
            ++compared;
            if (mine->at(0) != kv.second.at(0)) note(values, nvalues, kv.first);
            if (mine->at(1) != kv.second.at(1)) note(flags, nflags, kv.first);
        }
    }
    const bool has_ref = want.is_object() && want.size() > 0;
    const bool mix_values = has_ref && result["mix_values"] == reference["mix_values"];
    const bool mix_flags = has_ref && result["mix_flags"] == reference["mix_flags"];
    const size_t sigill = result["sigill"].is_array() ? result["sigill"].size() : 0;
    out.set("reference", has_ref);
    out.set("patterns", static_cast<int64_t>(compared));
    out.set("values_differ", static_cast<int64_t>(nvalues));
    out.set("flags_differ", static_cast<int64_t>(nflags));
    out.set("missing", static_cast<int64_t>(nmissing));
    out.set("values_differ_names", std::move(values));
    out.set("flags_differ_names", std::move(flags));
    out.set("missing_names", std::move(missing));
    out.set("mix_values_equal", mix_values);
    out.set("mix_flags_equal", mix_flags);
    out.set("sigill", static_cast<int64_t>(sigill));
    out.set("match", has_ref && compared > 0 && nvalues == 0 && nmissing == 0 && mix_values && sigill == 0);
    out.set("flags_match", has_ref && nflags == 0 && mix_flags);
    out.set("runs", result["runs"]);
    out.set("mix_runs", result["mix_runs"]);
    out.set("seconds", result["seconds"]);
    out.set("mix_seconds", result["mix_seconds"]);
    out.set("reference_cpu", reference["cpu"]);
    return out;
}

}  // namespace agent
