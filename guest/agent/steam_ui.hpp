// ideck-agent — keeps Steam's UI from using the emulated CPU while nobody
// looks at it (replaces the steam-ui-daemon shell loop of runtime 0.1.9).
//
// The app reports what the iPad shows (agent op steam.ui):
//   visible  the Linux screen shows Steam
//   game     the Linux screen shows (or is about to show) a game
//   away     the iPad shows iDeck's own screens; nobody sees Linux
//
// - Leaving "visible": Steam's mapped windows are minimised; Chromium stops
//   drawing minimised windows. In "away", windows that appear later are
//   minimised too. In "game" they are left alone, so dialogs a game launch
//   needs (EULA, Proton download, cloud conflicts) stay visible.
// - Back to "visible": the windows minimised here are restored; with none,
//   Steam is asked to open its main window.
// - steamwebhelper threads run at nice 19 unless Steam is visible and no
//   game runs. Not SCHED_IDLE: Steam must keep answering, or it reports
//   "steamwebhelper is not responding".
//
// The shell daemon spawned pgrep, runuser and xdotool every 3 s and used
// 7-15% of a vCPU in CI. This runs in the agent: /proc is read directly,
// nice is set with setpriority(), and xdotool only runs on state changes
// (and every 6 s while away, to catch new windows).
#pragma once

#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ideck/json.hpp"

namespace agent {

// Window ids from `xdotool search` output (one decimal id per line).
std::vector<std::string> parse_window_ids(const std::string& output);
// True for a NUL-separated /proc/<pid>/cmdline of Steam's game launcher
// ("reaper SteamLaunch AppId=<n> -- ...").
bool is_game_launch_cmdline(const std::string& cmdline);
// Nice value for steamwebhelper in a state.
int webhelper_nice_for(const std::string& state, bool game_running);
// The argv for one xdotool run that applies `command` to every id
// (xdotool chains commands: "windowminimize 1 windowminimize 2").
std::vector<std::string> xdotool_chain(const std::string& command, const std::vector<std::string>& ids);
// Chromium's process role from a NUL-separated cmdline ("--type=gpu-process"
// -> "gpu-process"; no --type means the browser process).
std::string chromium_process_type(const std::string& cmdline);
// Graphics libraries named in /proc/<pid>/maps text: Mesa's GL/gallium and
// Vulkan drivers (a Vulkan ICD in the GPU process means Zink is in use).
std::vector<std::string> graphics_libraries(const std::string& maps);
// Every steamwebhelper process with its role and graphics libraries.
ideck::Json webhelper_report();

class SteamUi {
public:
    SteamUi() = default;
    ~SteamUi();
    void start();
    // Requests a state; waits up to `wait_ms` until it is applied.
    // Returns the status (same fields as runtime 0.1.9's steam-ui.json).
    ideck::Json request(const std::string& state, int wait_ms);
    ideck::Json status();

private:
    void loop();
    void transition(const std::string& state);
    void periodic(const std::string& state, bool check_windows);
    void minimize_visible();
    void restore();

    std::mutex m_;
    std::condition_variable cv_;
    std::string want_ = "visible";
    std::string applied_;  // empty until the thread has applied a state
    ideck::Json status_ = ideck::Json::object();
    bool quit_ = false;
    std::thread thread_;
    // Owned by the thread:
    std::vector<std::string> minimized_;
    bool game_ = false;
    int nice_ = 0;
    int webhelpers_ = 0;
    bool steam_running_ = false;
};

}  // namespace agent
