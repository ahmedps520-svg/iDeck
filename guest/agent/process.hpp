// ideck-agent — running helper programs with a timeout.
#pragma once

#include <string>
#include <vector>

namespace agent {

struct RunResult {
    int exit_code = -1;   // -1: could not start / killed by timeout
    bool timed_out = false;
    std::string output;   // stdout + stderr, truncated to max_output
};

// Runs argv[0] (PATH lookup) without a shell. Output is captured.
RunResult run(const std::vector<std::string>& argv, int timeout_ms, size_t max_output = 256 * 1024);

// Starts argv detached (new session, output to /dev/null). Returns pid or -1.
int spawn_detached(const std::vector<std::string>& argv);

}  // namespace agent
