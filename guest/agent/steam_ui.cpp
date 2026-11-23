#include "steam_ui.hpp"

#include <chrono>
#include <cstdlib>
#include <cstring>

#include "sysinfo.hpp"

#if defined(__linux__)
#include <dirent.h>
#include <sys/resource.h>

#include "process.hpp"
#endif

namespace agent {

using ideck::Json;

std::vector<std::string> parse_window_ids(const std::string& output) {
    std::vector<std::string> ids;
    size_t pos = 0;
    while (pos < output.size()) {
        size_t end = output.find('\n', pos);
        if (end == std::string::npos) end = output.size();
        std::string line = output.substr(pos, end - pos);
        size_t a = line.find_first_not_of(" \t\r");
        size_t b = line.find_last_not_of(" \t\r");
        line = a == std::string::npos ? std::string() : line.substr(a, b - a + 1);
        if (!line.empty() && line.find_first_not_of("0123456789") == std::string::npos) ids.push_back(line);
        pos = end + 1;
    }
    return ids;
}

bool is_game_launch_cmdline(const std::string& cmdline) {
    bool launch = false, appid = false;
    size_t pos = 0;
    while (pos < cmdline.size()) {
        size_t end = cmdline.find('\0', pos);
        if (end == std::string::npos) end = cmdline.size();
        std::string arg = cmdline.substr(pos, end - pos);
        if (arg == "SteamLaunch") launch = true;
        if (arg.rfind("AppId=", 0) == 0 && arg.size() > 6) appid = true;
        pos = end + 1;
    }
    return launch && appid;
}

int webhelper_nice_for(const std::string& state, bool game_running) {
    return state == "visible" && !game_running ? 0 : 19;
}

std::vector<std::string> xdotool_chain(const std::string& command, const std::vector<std::string>& ids) {
    std::vector<std::string> argv = {"env", "DISPLAY=:0", "xdotool"};
    for (const auto& id : ids) {
        argv.push_back(command);
        argv.push_back(id);
    }
    return argv;
}

SteamUi::~SteamUi() {
    {
        std::lock_guard<std::mutex> l(m_);
        quit_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void SteamUi::start() {
#if defined(__linux__)
    thread_ = std::thread([this] { loop(); });
#endif
}

Json SteamUi::status() {
    std::lock_guard<std::mutex> l(m_);
    return status_;
}

Json SteamUi::request(const std::string& state, int wait_ms) {
    std::unique_lock<std::mutex> l(m_);
    want_ = state;
    cv_.notify_all();
    cv_.wait_for(l, std::chrono::milliseconds(wait_ms), [&] { return applied_ == state || quit_; });
    return status_;
}

#if defined(__linux__)

namespace {

// Visible top-level Steam windows (WM_CLASS steam or steamwebhelper; the
// session allows root on the X server for this).
std::vector<std::string> visible_windows() {
    RunResult r = run({"env", "DISPLAY=:0", "xdotool", "search", "--onlyvisible", "--class",
                       "^(steam|steamwebhelper)$"},
                      5000, 64 * 1024);
    return parse_window_ids(r.output);
}

struct ProcScan {
    std::vector<int> webhelpers;
    bool game = false;
    bool steam = false;
};

ProcScan scan_processes() {
    ProcScan s;
    DIR* d = opendir("/proc");
    if (!d) return s;
    while (dirent* e = readdir(d)) {
        char* end = nullptr;
        long pid = std::strtol(e->d_name, &end, 10);
        if (!end || *end || pid <= 0) continue;
        const std::string dir = "/proc/" + std::string(e->d_name);
        std::string comm = trimmed(read_text(dir + "/comm", 64));
        if (comm == "steamwebhelper") s.webhelpers.push_back(static_cast<int>(pid));
        if (comm == "steam") s.steam = true;
        if (!s.game && is_game_launch_cmdline(read_text(dir + "/cmdline", 4096))) s.game = true;
    }
    closedir(d);
    return s;
}

// Nice is per thread on Linux: every task of every web helper.
void set_nice(const std::vector<int>& pids, int nice) {
    for (int pid : pids) {
        const std::string task_dir = "/proc/" + std::to_string(pid) + "/task";
        DIR* d = opendir(task_dir.c_str());
        if (!d) continue;
        while (dirent* e = readdir(d)) {
            char* end = nullptr;
            long tid = std::strtol(e->d_name, &end, 10);
            if (!end || *end || tid <= 0) continue;
            ProcStat st;
            if (!parse_proc_stat(read_text(task_dir + "/" + e->d_name + "/stat", 4096), st)) continue;
            if (st.nice != nice) setpriority(PRIO_PROCESS, static_cast<id_t>(tid), nice);
        }
        closedir(d);
    }
}

}  // namespace

void SteamUi::minimize_visible() {
    std::vector<std::string> ids = visible_windows();
    if (ids.empty()) return;
    run(xdotool_chain("windowminimize", ids), 5000);
    for (const auto& id : ids) {
        bool known = false;
        for (const auto& m : minimized_) known = known || m == id;
        if (!known) minimized_.push_back(id);
    }
}

void SteamUi::restore() {
    bool restored = false;
    for (const auto& id : minimized_) {
        // One run per window: a window that closed meanwhile must not stop
        // the others (xdotool ends a chain at the first failing command).
        if (run({"env", "DISPLAY=:0", "xdotool", "windowactivate", id}, 5000).exit_code == 0) restored = true;
    }
    minimized_.clear();
    if (!restored && steam_running_ && visible_windows().empty()) {
        spawn_detached({"/usr/lib/ideck/ideck-steam-url", "steam://open/main"});
    }
}

void SteamUi::transition(const std::string& state) {
    if (state == "visible") {
        restore();
    } else {
        minimize_visible();
    }
}

void SteamUi::periodic(const std::string& state, bool check_windows) {
    ProcScan s = scan_processes();
    game_ = s.game;
    steam_running_ = s.steam;
    webhelpers_ = static_cast<int>(s.webhelpers.size());
    nice_ = webhelper_nice_for(state, game_);
    set_nice(s.webhelpers, nice_);
    if (state == "away" && check_windows) minimize_visible();
}

void SteamUi::loop() {
    // Starts as "visible" without a transition, like the old daemon: at boot
    // Steam may not have opened its window yet, and nothing is minimised.
    std::string applied = "visible";
    int tick = 0;
    for (;;) {
        std::string want;
        {
            std::unique_lock<std::mutex> l(m_);
            cv_.wait_for(l, std::chrono::seconds(1), [&] { return quit_ || want_ != applied; });
            if (quit_) return;
            want = want_;
        }
        bool changed = want != applied;
        if (changed) {
            periodic(want, false);  // game state and nice first, before windows move
            transition(want);
            applied = want;
            tick = 0;
        } else if (tick % 3 == 0) {
            periodic(want, tick % 6 == 0);
        }
        ++tick;
        Json st = Json::object();
        st.set("state", applied);
        st.set("game_running", game_);
        st.set("webhelper_nice", nice_);
        st.set("webhelpers", webhelpers_);
        st.set("minimized", static_cast<int>(minimized_.size()));
        {
            std::lock_guard<std::mutex> l(m_);
            status_ = std::move(st);
            applied_ = applied;
        }
        cv_.notify_all();
    }
}

#else

// Host builds (tests): no X server or /proc to manage.
void SteamUi::loop() {
    (void)game_;
    (void)nice_;
    (void)webhelpers_;
    (void)steam_running_;
}
void SteamUi::transition(const std::string&) {}
void SteamUi::periodic(const std::string&, bool) {}
void SteamUi::minimize_visible() {}
void SteamUi::restore() {}

#endif

}  // namespace agent
