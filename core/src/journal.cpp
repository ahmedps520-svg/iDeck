#include "ideck/journal.hpp"

#include "ideck/fsutil.hpp"

namespace ideck {

const char* step_state_name(StepState s) {
    switch (s) {
        case StepState::Pending: return "pending";
        case StepState::Running: return "running";
        case StepState::Done: return "done";
        case StepState::Failed: return "failed";
        case StepState::Skipped: return "skipped";
    }
    return "pending";
}

bool step_state_from_name(const std::string& n, StepState& out) {
    if (n == "pending") out = StepState::Pending;
    else if (n == "running") out = StepState::Running;
    else if (n == "done") out = StepState::Done;
    else if (n == "failed") out = StepState::Failed;
    else if (n == "skipped") out = StepState::Skipped;
    else return false;
    return true;
}

std::vector<JournalStep> InstallJournal::default_steps() {
    // Order matters: it is the order the installer executes. Steps after
    // "boot-guest" are performed inside the Linux guest by the provisioning
    // service and reported back through the guest agent.
    const char* table[][2] = {
        {"check-device", "Checking device compatibility"},
        {"check-storage", "Checking available storage"},
        {"check-distribution", "Checking JIT and signing configuration"},
        {"fetch-manifest", "Fetching runtime manifest"},
        {"download-runtime", "Downloading Linux runtime"},
        {"verify-runtime", "Verifying checksums"},
        {"install-runtime", "Installing runtime files"},
        {"create-storage", "Creating game storage"},
        {"boot-guest", "Starting Linux for the first time"},
        {"install-steam", "Installing Steam"},
        {"install-compat", "Installing compatibility tools"},
        {"init-graphics", "Initialising graphics"},
        {"init-audio", "Initialising audio"},
        {"init-input", "Configuring controllers"},
        {"self-test", "Running self-tests"},
        {"ready", "Ready to play"},
    };
    std::vector<JournalStep> steps;
    for (const auto& row : table) {
        JournalStep s;
        s.id = row[0];
        s.title = row[1];
        steps.push_back(std::move(s));
    }
    return steps;
}

Json InstallJournal::to_json() const {
    Json j = Json::object();
    j.set("schema", 1);
    j.set("runtime_version", runtime_version);
    j.set("app_build", app_build);
    Json arr = Json::array();
    for (const auto& s : steps_) {
        Json sj = Json::object();
        sj.set("id", s.id);
        sj.set("title", s.title);
        sj.set("state", step_state_name(s.state));
        sj.set("attempts", s.attempts);
        if (!s.error.empty()) sj.set("error", s.error);
        if (s.started_at) sj.set("started_at", s.started_at);
        if (s.finished_at) sj.set("finished_at", s.finished_at);
        if (!s.data.is_null()) sj.set("data", s.data);
        arr.push(std::move(sj));
    }
    j.set("steps", std::move(arr));
    return j;
}

bool InstallJournal::from_json(const Json& j, std::string* err) {
    if (!j.is_object() || j["schema"].as_int() != 1 || !j["steps"].is_array()) {
        if (err) *err = "journal has unsupported format";
        return false;
    }
    runtime_version = j["runtime_version"].as_string();
    app_build = j["app_build"].as_string();
    // Merge saved state onto the current step list, by id.
    for (auto& s : steps_) {
        for (const auto& sj : j["steps"].items()) {
            if (sj["id"].as_string() != s.id) continue;
            StepState st = StepState::Pending;
            if (!step_state_from_name(sj["state"].as_string(), st)) st = StepState::Pending;
            s.state = st;
            s.attempts = static_cast<int>(sj["attempts"].as_int(0));
            s.error = sj["error"].as_string();
            s.started_at = sj["started_at"].as_int(0);
            s.finished_at = sj["finished_at"].as_int(0);
            s.data = sj["data"];
            break;
        }
    }
    // A later step can't stay Done if an earlier one is not: the sequence is
    // dependent, so anything after the first unfinished step is invalidated.
    bool hole = false;
    for (auto& s : steps_) {
        if (hole && (s.state == StepState::Done || s.state == StepState::Skipped)) {
            s.state = StepState::Pending;
        }
        if (s.state != StepState::Done && s.state != StepState::Skipped) hole = true;
    }
    return true;
}

bool InstallJournal::load(const std::string& path, std::string* err) {
    if (steps_.empty()) steps_ = default_steps();
    std::string text;
    if (!read_file(path, text)) {
        if (err) *err = "cannot read journal";
        return false;
    }
    Json j;
    std::string perr;
    if (!Json::parse(text, j, &perr)) {
        if (err) *err = "journal is corrupt: " + perr;
        return false;
    }
    return from_json(j, err);
}

bool InstallJournal::save(const std::string& path) const {
    return write_file_atomic(path, to_json().dump(2));
}

const JournalStep* InstallJournal::next() const {
    for (const auto& s : steps_) {
        if (s.state != StepState::Done && s.state != StepState::Skipped) return &s;
    }
    return nullptr;
}

JournalStep* InstallJournal::find(const std::string& id) {
    for (auto& s : steps_) {
        if (s.id == id) return &s;
    }
    return nullptr;
}

const JournalStep* InstallJournal::find(const std::string& id) const {
    for (const auto& s : steps_) {
        if (s.id == id) return &s;
    }
    return nullptr;
}

bool InstallJournal::begin(const std::string& id, int64_t now) {
    const JournalStep* n = next();
    // Steps must run in order.
    if (!n || n->id != id) return false;
    JournalStep* s = find(id);
    s->state = StepState::Running;
    s->attempts += 1;
    s->error.clear();
    s->started_at = now;
    s->finished_at = 0;
    return true;
}

bool InstallJournal::complete(const std::string& id, int64_t now) {
    JournalStep* s = find(id);
    if (!s || s->state != StepState::Running) return false;
    s->state = StepState::Done;
    s->finished_at = now;
    return true;
}

bool InstallJournal::skip(const std::string& id, int64_t now) {
    JournalStep* s = find(id);
    if (!s || (s->state != StepState::Running && s->state != StepState::Pending)) return false;
    const JournalStep* n = next();
    if (!n || n->id != id) return false;
    s->state = StepState::Skipped;
    s->finished_at = now;
    return true;
}

bool InstallJournal::fail(const std::string& id, const std::string& error, int64_t now) {
    JournalStep* s = find(id);
    if (!s || s->state != StepState::Running) return false;
    s->state = StepState::Failed;
    s->error = error;
    s->finished_at = now;
    return true;
}

bool InstallJournal::reset_from(const std::string& id) {
    bool found = false;
    for (auto& s : steps_) {
        if (s.id == id) found = true;
        if (found) {
            s.state = StepState::Pending;
            s.error.clear();
            s.data = Json();
            s.started_at = 0;
            s.finished_at = 0;
        }
    }
    return found;
}

int InstallJournal::recover_interrupted() {
    int n = 0;
    for (auto& s : steps_) {
        if (s.state == StepState::Running) {
            s.state = StepState::Pending;
            ++n;
        }
    }
    return n;
}

bool InstallJournal::has_failure() const {
    for (const auto& s : steps_) {
        if (s.state == StepState::Failed) return true;
    }
    return false;
}

double InstallJournal::progress() const {
    if (steps_.empty()) return 1.0;
    size_t done = 0;
    for (const auto& s : steps_) {
        if (s.state == StepState::Done || s.state == StepState::Skipped) ++done;
    }
    return static_cast<double>(done) / static_cast<double>(steps_.size());
}

}  // namespace ideck
