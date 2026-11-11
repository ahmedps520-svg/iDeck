#include "sysinfo.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>

#if defined(__linux__)
#include <dirent.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <unistd.h>
#endif

namespace agent {

using ideck::Json;

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

}  // namespace agent
