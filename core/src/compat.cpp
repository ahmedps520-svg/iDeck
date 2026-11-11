#include "ideck/compat.hpp"

namespace ideck {

const char* compat_status_name(CompatStatus s) {
    switch (s) {
        case CompatStatus::Untested: return "untested";
        case CompatStatus::Broken: return "broken";
        case CompatStatus::Boots: return "boots";
        case CompatStatus::Menus: return "menus";
        case CompatStatus::Playable: return "playable";
        case CompatStatus::Verified: return "verified";
    }
    return "untested";
}

bool compat_status_from_name(const std::string& n, CompatStatus& out) {
    static const CompatStatus all[] = {CompatStatus::Untested, CompatStatus::Broken, CompatStatus::Boots,
                                       CompatStatus::Menus, CompatStatus::Playable, CompatStatus::Verified};
    for (auto s : all) {
        if (n == compat_status_name(s)) {
            out = s;
            return true;
        }
    }
    return false;
}

bool CompatDatabase::load_json(const std::string& text, std::string* err) {
    Json j;
    if (!Json::parse(text, j, err)) return false;
    if (!j.is_object() || j["schema"].as_int() != 1 || !j["games"].is_array()) {
        if (err) *err = "compat database must be {\"schema\":1,\"games\":[...]}";
        return false;
    }
    std::vector<CompatEntry> entries;
    for (const auto& g : j["games"].items()) {
        CompatEntry e;
        e.appid = static_cast<uint32_t>(g["appid"].as_int(0));
        if (e.appid == 0) {
            if (err) *err = "game entry without appid";
            return false;
        }
        e.name = g["name"].as_string();
        e.path = g["path"].as_string();
        if (e.path != "native-arm64" && e.path != "linux-x86" && e.path != "windows") {
            if (err) *err = "game " + std::to_string(e.appid) + " has invalid path '" + e.path + "'";
            return false;
        }
        if (!compat_status_from_name(g["status"].as_string(), e.status)) {
            if (err) *err = "game " + std::to_string(e.appid) + " has invalid status";
            return false;
        }
        // A claim above "untested" must say when, on what, and by whom.
        if (e.status != CompatStatus::Untested) {
            e.tested_at = g["tested_at"].as_string();
            e.runtime_version = g["runtime_version"].as_string();
            e.tester = g["tester"].as_string();
            if (e.tested_at.empty() || e.runtime_version.empty()) {
                if (err) *err = "game " + std::to_string(e.appid) + " has a result without tested_at/runtime_version";
                return false;
            }
        }
        e.fps_avg = g["fps_avg"].as_double(0);
        e.resolution_h = static_cast<int>(g["resolution_h"].as_int(0));
        e.notes = g["notes"].as_string();
        e.launch_options = g["launch_options"];
        entries.push_back(std::move(e));
    }
    entries_ = std::move(entries);
    return true;
}

std::string CompatDatabase::dump() const {
    Json j = Json::object();
    j.set("schema", 1);
    Json games = Json::array();
    for (const auto& e : entries_) {
        Json g = Json::object();
        g.set("appid", e.appid);
        g.set("name", e.name);
        g.set("path", e.path);
        g.set("status", compat_status_name(e.status));
        if (e.fps_avg > 0) g.set("fps_avg", e.fps_avg);
        if (e.resolution_h > 0) g.set("resolution_h", e.resolution_h);
        if (!e.runtime_version.empty()) g.set("runtime_version", e.runtime_version);
        if (!e.tested_at.empty()) g.set("tested_at", e.tested_at);
        if (!e.tester.empty()) g.set("tester", e.tester);
        if (!e.notes.empty()) g.set("notes", e.notes);
        if (!e.launch_options.is_null()) g.set("launch_options", e.launch_options);
        games.push(std::move(g));
    }
    j.set("games", std::move(games));
    return j.dump(2);
}

const CompatEntry* CompatDatabase::find(uint32_t appid) const {
    for (const auto& e : entries_) {
        if (e.appid == appid) return &e;
    }
    return nullptr;
}

void CompatDatabase::upsert(const CompatEntry& e) {
    for (auto& x : entries_) {
        if (x.appid == e.appid) {
            x = e;
            return;
        }
    }
    entries_.push_back(e);
}

}  // namespace ideck
