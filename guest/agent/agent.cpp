// ideck-agent — the iDeck guest agent.
//
// Runs as a root systemd service inside the Linux guest. Talks to the iPad
// app over two virtio-serial ports:
//   org.ideck.control  newline-delimited JSON requests/responses/events
//   org.ideck.input    32-byte controller packets (host -> guest) and
//                      rumble packets (guest -> host)
//
// The main thread only does I/O and controller translation so input latency
// is never affected by slow requests; anything that runs a helper program is
// executed on a worker thread.
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "gamepad.hpp"
#include "ideck/json.hpp"
#include "ideck/protocol.hpp"
#include "process.hpp"
#include "sysinfo.hpp"

#if defined(__linux__)
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#endif

using ideck::Json;

namespace {

constexpr const char* kAgentVersion = "0.1.0";
constexpr const char* kLibDir = "/usr/lib/ideck";
constexpr const char* kStateDir = "/var/lib/ideck";
constexpr const char* kDataDiskDev = "/dev/disk/by-id/virtio-ideck-data";
constexpr size_t kMaxPending = 1 << 20;

#if defined(__linux__)

volatile sig_atomic_t g_stop = 0;
void on_signal(int) { g_stop = 1; }

int64_t mono_ms() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

int64_t file_mtime_ns(const std::string& path) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return 0;
    return static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec;
}

struct Port {
    std::string path;
    int fd = -1;
    std::string out;
    int64_t retry_at = 0;      // reopen / HUP backoff
    bool host_connected = false;

    bool ensure_open(int64_t now) {
        if (fd >= 0) return true;
        if (now < retry_at) return false;
        fd = open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) {
            retry_at = now + 1000;
            return false;
        }
        return true;
    }

    void queue(const std::string& data, bool droppable) {
        if (droppable && out.size() + data.size() > kMaxPending) return;
        out += data;
    }

    void flush() {
        while (fd >= 0 && !out.empty()) {
            ssize_t n = write(fd, out.data(), out.size());
            if (n > 0) {
                out.erase(0, static_cast<size_t>(n));
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
            // Host side gone: keep the port open, drop stale output.
            out.clear();
            return;
        }
    }
};

Json parse_json_or_text(const std::string& s) {
    Json j;
    if (Json::parse(s, j)) return j;
    Json t = Json::object();
    t.set("text", s);
    return t;
}

Json read_json_file(const std::string& path) {
    std::string text = agent::read_text(path);
    Json j;
    if (text.empty() || !Json::parse(text, j)) return Json();
    return j;
}

bool write_proc(const char* path, const char* value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return false;
    bool ok = write(fd, value, std::strlen(value)) == static_cast<ssize_t>(std::strlen(value));
    close(fd);
    return ok;
}

bool unit_allowed(const std::string& unit) {
    if (unit.rfind("ideck-", 0) == 0) return unit.find('/') == std::string::npos;
    return unit == "systemd-journald.service";
}

std::string lib(const char* name) { return std::string(kLibDir) + "/" + name; }

// ---- requests ------------------------------------------------------------

struct Job {
    int64_t id;
    std::string op;
    Json args;
};

struct Reply {
    int64_t id;
    bool ok;
    Json result;
    std::string error;
};

Json run_to_json(const std::vector<std::string>& argv, int timeout_ms) {
    agent::RunResult r = agent::run(argv, timeout_ms);
    Json j = Json::object();
    j.set("exit_code", r.exit_code);
    j.set("timed_out", r.timed_out);
    j.set("output", r.output);
    return j;
}

// Slow operations: run on the worker thread.
Reply execute_slow(const Job& job) {
    Reply rep{job.id, true, Json::object(), {}};
    const Json& a = job.args;
    auto fail = [&](const std::string& e) {
        rep.ok = false;
        rep.error = e;
        return rep;
    };
    if (job.op == "steam.start" || job.op == "steam.stop" || job.op == "steam.restart") {
        std::string verb = job.op.substr(6);
        // --no-block: queue the job and return. Stopping Steam can take up
        // to the unit's 30 s TimeoutStopSec, so waiting for a restart ran
        // past this call's own timeout and reported a failure (runtime
        // 0.1.5 boot test).
        rep.result = run_to_json({"systemctl", "--no-block", verb, "ideck-steam.service"}, 15000);
        if (rep.result["exit_code"].as_int() != 0) {
            return fail("systemctl " + verb + " failed: " + rep.result["output"].as_string());
        }
        return rep;
    }
    if (job.op == "steam.status") {
        Json r = Json::object();
        Json active = run_to_json({"systemctl", "is-active", "ideck-steam.service"}, 5000);
        std::string state = active["output"].as_string();
        while (!state.empty() && (state.back() == '\n')) state.pop_back();
        r.set("service", state);
        Json pids = Json::array();
        for (int p : agent::find_processes("steamrtarm64/steam")) pids.push(p);
        r.set("pids", std::move(pids));
        r.set("bootstrap", read_json_file("/home/deck/.local/share/ideck/steam-bootstrap.json"));
        rep.result = std::move(r);
        return rep;
    }
    if (job.op == "steam.configure") {
        // Launch preferences read by ideck-steam-launch.
        std::string env;
        env += std::string("IDECK_STEAM_BIGPICTURE=") + (a["bigpicture"].as_bool(false) ? "1" : "0") + "\n";
        env += std::string("IDECK_STEAM_BETA=") + (a["beta"].as_bool(false) ? "1" : "0") + "\n";
        env += std::string("IDECK_STEAM_CEF_NOGPU=") + (a["cef_software"].as_bool(false) ? "1" : "0") + "\n";
        env += std::string("IDECK_MANGOHUD=") + (a["overlay"].as_bool(false) ? "1" : "0") + "\n";
        // /var/lib/ideck is read by the launcher; the copy on the library
        // disk survives runtime updates (system disk replacement).
        const std::string paths[] = {std::string(kStateDir) + "/steam.env", "/home/.ideck/steam.env"};
        for (const std::string& path : paths) {
            std::string tmp = path + ".tmp";
            std::FILE* f = std::fopen(tmp.c_str(), "wb");
            if (!f) return fail("cannot write " + path);
            std::fwrite(env.data(), 1, env.size(), f);
            std::fclose(f);
            if (std::rename(tmp.c_str(), path.c_str()) != 0) return fail("cannot replace " + path);
        }
        return rep;
    }
    if (job.op == "steam.open") {
        // Hands a steam:// URL to the running client (run a game, open the
        // downloads page, ...). Only a fixed set of commands is accepted.
        std::string url = a["url"].as_string();
        static const char* allowed[] = {"steam://rungameid/", "steam://open/", "steam://nav/", "steam://install/",
                                        "steam://store/", "steam://url/", "steam://validate/"};
        bool ok = false;
        for (const char* p : allowed) ok = ok || url.rfind(p, 0) == 0;
        for (char ch : url) ok = ok && ch > 0x20 && ch != '\'' && ch != '"' && ch != '`' && ch != '\\';
        if (!ok) return fail("steam URL not allowed");
        rep.result = run_to_json({lib("ideck-steam-url"), url}, 30000);
        if (rep.result["exit_code"].as_int() != 0) return fail("Steam did not accept the request");
        return rep;
    }
    if (job.op == "steam.library") {
        agent::RunResult r =
            agent::run({"runuser", "-u", "deck", "--", "python3", lib("steam_library.py")}, 60000, 4 << 20);
        if (r.exit_code != 0) return fail("could not read the Steam library: " + r.output.substr(0, 500));
        rep.result = parse_json_or_text(r.output);
        return rep;
    }
    if (job.op == "provision.retry") {
        rep.result = run_to_json({"systemctl", "restart", "--no-block", "ideck-provision.service"}, 15000);
        return rep;
    }
    if (job.op == "disk.resize") {
        rep.result = run_to_json({"resize2fs", kDataDiskDev}, 15 * 60 * 1000);
        if (rep.result["exit_code"].as_int() != 0) return fail("resize2fs failed");
        return rep;
    }
    if (job.op == "display.set") {
        int w = static_cast<int>(a["width"].as_int(0));
        int h = static_cast<int>(a["height"].as_int(0));
        if (w < 640 || h < 360 || w > 3840 || h > 2160) return fail("resolution out of range");
        rep.result = run_to_json({lib("set-resolution"), std::to_string(w), std::to_string(h)}, 20000);
        if (rep.result["exit_code"].as_int() != 0) return fail("set-resolution failed");
        return rep;
    }
    if (job.op == "bench.run") {
        std::vector<std::string> argv = {lib("ideck-bench"), "--json"};
        if (a["quick"].as_bool(false)) argv.push_back("--quick");
        agent::RunResult r = agent::run(argv, 20 * 60 * 1000, 1 << 20);
        if (r.exit_code != 0) return fail("benchmark failed: " + r.output.substr(0, 2000));
        rep.result = parse_json_or_text(r.output);
        return rep;
    }
    if (job.op == "selftest.run") {
        agent::RunResult r = agent::run({"python3", lib("self_test.py"), "--json"}, 10 * 60 * 1000, 1 << 20);
        rep.result = parse_json_or_text(r.output);
        if (r.exit_code != 0 && !rep.result.is_object()) return fail("self-test could not run");
        return rep;
    }
    if (job.op == "logs") {
        std::string unit = a["unit"].string_or("ideck-provision.service");
        if (!unit_allowed(unit)) return fail("unit not allowed");
        int lines = static_cast<int>(a["lines"].as_int(200));
        if (lines < 1 || lines > 5000) lines = 200;
        rep.result = run_to_json({"journalctl", "--no-pager", "-o", "short-monotonic", "-u", unit, "-n",
                                  std::to_string(lines)},
                                 15000);
        return rep;
    }
    if (job.op == "vulkan.info") {
        rep.result = run_to_json({"vulkaninfo", "--summary"}, 60000);
        return rep;
    }
    return fail("unknown op '" + job.op + "'");
}

class Worker {
public:
    explicit Worker(int wake_fd) : wake_fd_(wake_fd), thread_([this] { loop(); }) {}
    ~Worker() {
        {
            std::lock_guard<std::mutex> l(m_);
            quit_ = true;
        }
        cv_.notify_all();
        thread_.join();
    }
    void submit(Job j) {
        {
            std::lock_guard<std::mutex> l(m_);
            jobs_.push_back(std::move(j));
        }
        cv_.notify_one();
    }
    std::vector<Reply> take() {
        std::lock_guard<std::mutex> l(m_);
        std::vector<Reply> out(done_.begin(), done_.end());
        done_.clear();
        return out;
    }

private:
    void loop() {
        while (true) {
            Job j;
            {
                std::unique_lock<std::mutex> l(m_);
                cv_.wait(l, [&] { return quit_ || !jobs_.empty(); });
                if (quit_) return;
                j = std::move(jobs_.front());
                jobs_.pop_front();
            }
            Reply r = execute_slow(j);
            {
                std::lock_guard<std::mutex> l(m_);
                done_.push_back(std::move(r));
            }
            char b = 1;
            (void)!write(wake_fd_, &b, 1);
        }
    }

    int wake_fd_;
    std::mutex m_;
    std::condition_variable cv_;
    std::deque<Job> jobs_;
    std::deque<Reply> done_;
    bool quit_ = false;
    std::thread thread_;
};

struct Agent {
    Port control;
    Port input;
    ideck::LineFramer framer;
    ideck::InputStreamDecoder decoder;
    agent::GamepadHub pads{[this](const ideck::InputPacket& p) { send_input(p); }};
    std::vector<agent::CpuTimes> cpu_prev = agent::read_cpu_times();
    int64_t next_metrics = 0;
    int64_t next_provision_check = 0;
    int64_t provision_mtime = 0;
    bool sent_ready = false;

    void send_input(const ideck::InputPacket& p) {
        uint8_t buf[ideck::kInputPacketSize];
        ideck::encode_input(p, buf);
        input.queue(std::string(reinterpret_cast<char*>(buf), sizeof(buf)), true);
        input.flush();
    }

    void send(const std::string& line, bool droppable = false) {
        control.queue(line, droppable);
        control.flush();
    }

    Json hello() {
        Json j = agent::static_info();
        j.set("agent_version", kAgentVersion);
        j.set("protocol", ideck::kProtocolVersion);
        j.set("provision", read_json_file(std::string(kStateDir) + "/provision.json"));
        return j;
    }

    // Fast operations answered inline; returns false if `op` is slow.
    bool execute_fast(const ideck::ControlMessage& m) {
        const Json& a = m.args;
        if (m.op == "ping") {
            Json r = Json::object();
            r.set("pong", true);
            send(ideck::make_response(m.id, r));
        } else if (m.op == "hello" || m.op == "info") {
            send(ideck::make_response(m.id, hello()));
        } else if (m.op == "status") {
            std::vector<agent::CpuTimes> now;
            Json st = agent::dynamic_status(cpu_prev, now);
            cpu_prev = now;
            send(ideck::make_response(m.id, st));
        } else if (m.op == "input.devices") {
            // Names of input devices the kernel knows (verifies virtual pads).
            Json names = Json::array();
            std::string all = agent::read_text("/proc/bus/input/devices");
            size_t pos = 0;
            while ((pos = all.find("N: Name=\"", pos)) != std::string::npos) {
                pos += 9;
                size_t end = all.find('"', pos);
                if (end == std::string::npos) break;
                names.push(all.substr(pos, end - pos));
                pos = end;
            }
            Json r = Json::object();
            r.set("devices", std::move(names));
            send(ideck::make_response(m.id, r));
        } else if (m.op == "provision.status") {
            send(ideck::make_response(m.id, read_json_file(std::string(kStateDir) + "/provision.json")));
        } else if (m.op == "time.sync") {
            int64_t ms = a["unix_ms"].as_int(0);
            if (ms <= 0) {
                send(ideck::make_error(m.id, "unix_ms required"));
                return true;
            }
            timespec ts{static_cast<time_t>(ms / 1000), static_cast<long>((ms % 1000) * 1000000)};
            if (clock_settime(CLOCK_REALTIME, &ts) != 0) send(ideck::make_error(m.id, std::strerror(errno)));
            else send(ideck::make_response(m.id, Json::object()));
        } else if (m.op == "mem.drop_caches") {
            sync();
            bool ok = write_proc("/proc/sys/vm/drop_caches", "3");
            write_proc("/proc/sys/vm/compact_memory", "1");
            if (ok) send(ideck::make_response(m.id, Json::object()));
            else send(ideck::make_error(m.id, "cannot drop caches"));
        } else if (m.op == "fs.sync") {
            sync();
            send(ideck::make_response(m.id, Json::object()));
        } else if (m.op == "power.off" || m.op == "power.reboot") {
            sync();
            send(ideck::make_response(m.id, Json::object()));
            send(ideck::make_event("shutdown", Json::object()));
            agent::spawn_detached({"systemctl", m.op == "power.off" ? "poweroff" : "reboot"});
        } else {
            return false;
        }
        return true;
    }

    void on_control_bytes(const char* data, size_t n, Worker& worker) {
        for (const auto& line : framer.feed(std::string_view(data, n))) {
            ideck::ControlMessage m = ideck::parse_control_line(line);
            if (m.kind != ideck::ControlMessage::Kind::Request) {
                if (m.kind == ideck::ControlMessage::Kind::Invalid) {
                    send(ideck::make_error(m.id, "bad request: " + m.error));
                }
                continue;
            }
            if (!execute_fast(m)) worker.submit(Job{m.id, m.op, m.args});
        }
    }

    void tick(int64_t now) {
        if (!sent_ready && control.fd >= 0) {
            send(ideck::make_event("ready", hello()));
            sent_ready = true;
        }
        if (now >= next_metrics) {
            next_metrics = now + 2000;
            std::vector<agent::CpuTimes> cur;
            Json st = agent::dynamic_status(cpu_prev, cur);
            cpu_prev = cur;
            send(ideck::make_event("metrics", st), true);
        }
        if (now >= next_provision_check) {
            next_provision_check = now + 1000;
            std::string path = std::string(kStateDir) + "/provision.json";
            int64_t mt = file_mtime_ns(path);
            if (mt && mt != provision_mtime) {
                provision_mtime = mt;
                send(ideck::make_event("provision", read_json_file(path)), true);
            }
        }
    }
};

int run_agent(const std::string& control_path, const std::string& input_path) {
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    int wake[2];
    if (pipe2(wake, O_CLOEXEC | O_NONBLOCK) != 0) return 1;
    Agent ag;
    ag.control.path = control_path;
    ag.input.path = input_path;
    Worker worker(wake[1]);
    std::fprintf(stderr, "ideck-agent %s: control=%s input=%s\n", kAgentVersion, control_path.c_str(),
                 input_path.c_str());

    char buf[65536];
    while (!g_stop) {
        int64_t now = mono_ms();
        ag.control.ensure_open(now);
        ag.input.ensure_open(now);

        std::vector<pollfd> fds;
        fds.push_back({wake[0], POLLIN, 0});
        auto add_port = [&](Port& p) {
            if (p.fd < 0 || now < p.retry_at) return -1;
            short ev = POLLIN;
            if (!p.out.empty()) ev |= POLLOUT;
            fds.push_back({p.fd, ev, 0});
            return static_cast<int>(fds.size() - 1);
        };
        int ci = add_port(ag.control);
        int ii = add_port(ag.input);
        size_t pad_base = fds.size();
        std::vector<int> pad_fds = ag.pads.fds();
        for (int fd : pad_fds) fds.push_back({fd, POLLIN, 0});

        int n = poll(fds.data(), fds.size(), 250);
        now = mono_ms();
        if (n < 0 && errno != EINTR) break;

        if (fds[0].revents & POLLIN) {
            char tmp[64];
            while (read(wake[0], tmp, sizeof(tmp)) > 0) {
            }
        }
        for (const auto& r : worker.take()) {
            ag.send(r.ok ? ideck::make_response(r.id, r.result) : ideck::make_error(r.id, r.error));
        }

        auto service_port = [&](Port& p, int idx, bool is_control) {
            if (idx < 0) return;
            short re = fds[static_cast<size_t>(idx)].revents;
            if (re & POLLHUP) {
                // virtio-serial reports HUP while no host client is
                // connected; back off instead of spinning.
                if (p.host_connected && is_control) ag.sent_ready = false;
                p.host_connected = false;
                p.retry_at = now + 250;
            } else if (re & (POLLIN | POLLOUT)) {
                if (!p.host_connected && is_control) ag.sent_ready = false;  // re-announce
                p.host_connected = true;
            }
            if (re & POLLIN) {
                ssize_t got = read(p.fd, buf, sizeof(buf));
                if (got > 0) {
                    if (is_control) {
                        ag.on_control_bytes(buf, static_cast<size_t>(got), worker);
                    } else {
                        for (const auto& pkt :
                             ag.decoder.feed(reinterpret_cast<uint8_t*>(buf), static_cast<size_t>(got))) {
                            ag.pads.handle(pkt);
                        }
                    }
                }
            }
            if (re & POLLOUT) p.flush();
        };
        service_port(ag.control, ci, true);
        service_port(ag.input, ii, false);
        for (size_t i = 0; i < pad_fds.size(); ++i) {
            if (fds[pad_base + i].revents & POLLIN) ag.pads.service(pad_fds[i]);
        }
        ag.tick(now);
    }
    ag.send(ideck::make_event("shutdown", Json::object()));
    ag.pads.disconnect_all();
    return 0;
}

#endif  // __linux__

}  // namespace

int main(int argc, char** argv) {
    std::string control = std::string("/dev/virtio-ports/") + ideck::kControlPortName;
    std::string input = std::string("/dev/virtio-ports/") + ideck::kInputPortName;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--control" && i + 1 < argc) control = argv[++i];
        else if (a == "--input" && i + 1 < argc) input = argv[++i];
        else if (a == "--version") {
            std::printf("ideck-agent %s (protocol %d)\n", kAgentVersion, ideck::kProtocolVersion);
            return 0;
        } else if (a == "--info") {
            std::printf("%s\n", agent::static_info().dump(2).c_str());
            return 0;
        } else {
            std::fprintf(stderr, "usage: ideck-agent [--control PATH] [--input PATH] [--info] [--version]\n");
            return 2;
        }
    }
#if defined(__linux__)
    return run_agent(control, input);
#else
    std::fprintf(stderr, "ideck-agent only runs on Linux\n");
    return 1;
#endif
}
