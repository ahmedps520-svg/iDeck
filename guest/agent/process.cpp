#include "process.hpp"

#if defined(__linux__)
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#endif

namespace agent {

#if defined(__linux__)

namespace {

int64_t now_ms() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

std::vector<char*> c_argv(const std::vector<std::string>& argv) {
    std::vector<char*> out;
    for (const auto& a : argv) out.push_back(const_cast<char*>(a.c_str()));
    out.push_back(nullptr);
    return out;
}

}  // namespace

RunResult run(const std::vector<std::string>& argv, int timeout_ms, size_t max_output) {
    RunResult r;
    if (argv.empty()) return r;
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC) != 0) return r;
    auto args = c_argv(argv);
    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return r;
    }
    if (pid == 0) {
        setpgid(0, 0);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) dup2(devnull, STDIN_FILENO);
        execvp(args[0], args.data());
        _exit(127);
    }
    close(pipefd[1]);
    int64_t deadline = now_ms() + timeout_ms;
    char buf[4096];
    while (true) {
        int64_t left = deadline - now_ms();
        if (left <= 0) {
            r.timed_out = true;
            kill(-pid, SIGKILL);
            break;
        }
        pollfd p{pipefd[0], POLLIN, 0};
        int n = poll(&p, 1, static_cast<int>(left));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) continue;
        ssize_t got = read(pipefd[0], buf, sizeof(buf));
        if (got <= 0) break;
        if (r.output.size() < max_output) {
            r.output.append(buf, static_cast<size_t>(got));
            if (r.output.size() > max_output) r.output.resize(max_output);
        }
    }
    close(pipefd[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (!r.timed_out && WIFEXITED(status)) r.exit_code = WEXITSTATUS(status);
    return r;
}

int spawn_detached(const std::vector<std::string>& argv) {
    if (argv.empty()) return -1;
    auto args = c_argv(argv);
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
        }
        execvp(args[0], args.data());
        _exit(127);
    }
    return pid;
}

#else

RunResult run(const std::vector<std::string>&, int, size_t) { return {}; }
int spawn_detached(const std::vector<std::string>&) { return -1; }

#endif

}  // namespace agent
