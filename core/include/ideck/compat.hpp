// iDeck core — game compatibility database.
//
// Entries are only ever written from real test runs (see COMPATIBILITY.md
// for the procedure). The shipped database starts empty of claims; the app
// shows "Untested" for anything without an entry.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "ideck/json.hpp"

namespace ideck {

enum class CompatStatus { Untested, Broken, Boots, Menus, Playable, Verified };

const char* compat_status_name(CompatStatus s);
bool compat_status_from_name(const std::string& n, CompatStatus& out);

struct CompatEntry {
    uint32_t appid = 0;
    std::string name;
    std::string path;        // native-arm64 | linux-x86 (FEX) | windows (Proton)
    CompatStatus status = CompatStatus::Untested;
    double fps_avg = 0;      // 0 = not measured
    int resolution_h = 0;    // e.g. 720
    std::string runtime_version;
    std::string tested_at;   // ISO date
    std::string tester;
    std::string notes;
    Json launch_options;     // e.g. {"PROTON_USE_WINED3D":"1"}
};

class CompatDatabase {
public:
    bool load_json(const std::string& text, std::string* err = nullptr);
    std::string dump() const;
    const CompatEntry* find(uint32_t appid) const;
    // Inserts or replaces (newest test wins).
    void upsert(const CompatEntry& e);
    const std::vector<CompatEntry>& entries() const { return entries_; }

private:
    std::vector<CompatEntry> entries_;
};

}  // namespace ideck
