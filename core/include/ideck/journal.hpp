// iDeck core — persistent install journal.
//
// The first-run installer is a fixed sequence of steps. Progress is written
// to disk after every transition so an interrupted install (app killed,
// device rebooted, download dropped) resumes at the first unfinished step
// instead of starting over. Steps that were "running" when the app died are
// demoted to "pending" by recover_interrupted() at launch and retried.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "ideck/json.hpp"

namespace ideck {

enum class StepState { Pending, Running, Done, Failed, Skipped };

const char* step_state_name(StepState s);
bool step_state_from_name(const std::string& n, StepState& out);

struct JournalStep {
    std::string id;
    std::string title;
    StepState state = StepState::Pending;
    int attempts = 0;
    std::string error;
    int64_t started_at = 0;   // unix seconds
    int64_t finished_at = 0;
    Json data;                // step-private resume data (e.g. bytes downloaded)
};

class InstallJournal {
public:
    // The canonical iDeck first-run sequence.
    static std::vector<JournalStep> default_steps();

    InstallJournal() = default;
    explicit InstallJournal(std::vector<JournalStep> steps) : steps_(std::move(steps)) {}

    // Loads from disk. Unknown/extra steps in the file are dropped, missing
    // ones are added as pending, so app updates can change the sequence.
    bool load(const std::string& path, std::string* err = nullptr);
    bool save(const std::string& path) const;

    Json to_json() const;
    bool from_json(const Json& j, std::string* err = nullptr);

    // First step that is not Done/Skipped, or nullptr when complete.
    const JournalStep* next() const;
    JournalStep* find(const std::string& id);
    const JournalStep* find(const std::string& id) const;

    bool begin(const std::string& id, int64_t now);
    bool complete(const std::string& id, int64_t now);
    bool skip(const std::string& id, int64_t now);
    bool fail(const std::string& id, const std::string& error, int64_t now);
    // Rollback: resets `id` and every later step to Pending.
    bool reset_from(const std::string& id);
    // Call once at app launch: a step still "running" was interrupted by the
    // app being killed, so it is demoted to Pending and retried. Returns the
    // number of steps recovered.
    int recover_interrupted();

    bool is_complete() const { return next() == nullptr; }
    bool has_failure() const;
    // 0..1 progress by step count (Done/Skipped).
    double progress() const;

    const std::vector<JournalStep>& steps() const { return steps_; }

    std::string runtime_version;  // version being installed
    std::string app_build;        // build that wrote the journal

private:
    std::vector<JournalStep> steps_;
};

}  // namespace ideck
