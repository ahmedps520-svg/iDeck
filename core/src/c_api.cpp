#include "ideck_core.h"

#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <map>
#include <string>

#include "ideck/compat.hpp"
#include "ideck/fsutil.hpp"
#include "ideck/journal.hpp"
#include "ideck/json.hpp"
#include "ideck/manifest.hpp"
#include "ideck/memory_planner.hpp"
#include "ideck/protocol.hpp"
#include "ideck/qemu_args.hpp"
#include "ideck/sha256.hpp"
#include "ideck/storage.hpp"

using namespace ideck;

namespace {

constexpr const char* kVersion = "0.1.0";

struct CallError {
    std::string message;
};

char* dup_string(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (!p) return nullptr;
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = '\0';
    return p;
}

const std::string& require_string(const Json& args, const char* key) {
    const Json& v = args[key];
    if (!v.is_string() || v.as_string().empty()) throw CallError{std::string("missing string argument '") + key + "'"};
    return v.as_string();
}

uint64_t u64(const Json& args, const char* key, uint64_t def = 0) {
    const Json& v = args[key];
    if (!v.is_number()) return def;
    int64_t x = v.as_int();
    return x < 0 ? 0 : static_cast<uint64_t>(x);
}

int64_t now_unix() { return static_cast<int64_t>(std::time(nullptr)); }

InstallJournal load_or_create_journal(const std::string& path) {
    InstallJournal j(InstallJournal::default_steps());
    if (path_exists(path)) {
        std::string err;
        if (!j.load(path, &err)) {
            // A corrupt journal must not brick setup: start over, keep a copy.
            rename_path(path, path + ".corrupt");
            j = InstallJournal(InstallJournal::default_steps());
        }
    }
    return j;
}

Json journal_op(const Json& args, const std::function<bool(InstallJournal&)>& op, const char* what) {
    const std::string& path = require_string(args, "path");
    InstallJournal j = load_or_create_journal(path);
    if (args["runtime_version"].is_string()) j.runtime_version = args["runtime_version"].as_string();
    if (args["app_build"].is_string()) j.app_build = args["app_build"].as_string();
    if (op && !op(j)) throw CallError{std::string("journal: cannot ") + what + " in the current state"};
    if (!j.save(path)) throw CallError{"journal: cannot write " + path};
    return j.to_json();
}

using Handler = std::function<Json(const Json&)>;

const std::map<std::string, Handler>& handlers() {
    static const std::map<std::string, Handler> h = {
        {"memory.plan",
         [](const Json& a) {
             MemoryInputs in;
             in.physical_mb = u64(a, "physical_mb");
             in.app_limit_mb = u64(a, "app_limit_mb");
             in.current_footprint_mb = u64(a, "current_footprint_mb");
             in.increased_memory_limit = a["increased_memory_limit"].as_bool(false);
             in.user_guest_mb = u64(a, "user_guest_mb");
             in.cpus = static_cast<int>(a["cpus"].as_int(4));
             in.vulkan = a["vulkan"].as_bool(true);
             return plan_memory(in).to_json();
         }},
        {"memory.pressure",
         [](const Json& a) {
             std::string level = a["level"].string_or("normal");
             PressureLevel l = PressureLevel::Normal;
             if (level == "warning") l = PressureLevel::Warning;
             else if (level == "critical") l = PressureLevel::Critical;
             else if (level != "normal") throw CallError{"unknown pressure level '" + level + "'"};
             PressureActions act = pressure_actions(l, u64(a, "guest_mb"), u64(a, "used_guest_mb"));
             Json r = Json::object();
             r.set("drop_guest_caches", act.drop_guest_caches);
             r.set("balloon_target_mb", act.balloon_target_mb);
             r.set("release_ui_caches", act.release_ui_caches);
             r.set("flush_disks", act.flush_disks);
             r.set("notify_user", act.notify_user);
             r.set("throttle_downloads", act.throttle_downloads);
             return r;
         }},
        {"qemu.args",
         [](const Json& a) {
             VmConfig cfg;
             std::string err;
             if (!vm_config_from_json(a, cfg, &err)) throw CallError{err};
             QemuArgsResult res = build_qemu_args(cfg);
             if (!res.ok) {
                 std::string msg = "invalid VM configuration:";
                 for (const auto& e : res.errors) msg += " " + e + ";";
                 throw CallError{msg};
             }
             Json r = Json::object();
             Json argv = Json::array();
             for (const auto& s : res.argv) argv.push(s);
             r.set("argv", std::move(argv));
             Json w = Json::array();
             for (const auto& s : res.warnings) w.push(s);
             r.set("warnings", std::move(w));
             return r;
         }},
        {"manifest.validate",
         [](const Json& a) {
             Manifest m;
             std::vector<std::string> errors;
             if (!parse_manifest(require_string(a, "text"), m, errors)) {
                 std::string msg = "manifest rejected:";
                 for (const auto& e : errors) msg += " " + e + ";";
                 throw CallError{msg};
             }
             Json r = manifest_to_json(m);
             r.set("total_download_size", m.total_download_size());
             r.set("total_installed_size", m.total_installed_size());
             return r;
         }},
        {"journal.load",
         [](const Json& a) {
             // {"recover":true} at app launch retries steps interrupted by a kill.
             bool recover = a["recover"].as_bool(false);
             return journal_op(
                 a, [&](InstallJournal& j) { if (recover) j.recover_interrupted(); return true; }, "load");
         }},
        {"journal.begin",
         [](const Json& a) {
             std::string id = require_string(a, "id");
             return journal_op(a, [&](InstallJournal& j) { return j.begin(id, now_unix()); }, "begin step");
         }},
        {"journal.complete",
         [](const Json& a) {
             std::string id = require_string(a, "id");
             return journal_op(a, [&](InstallJournal& j) { return j.complete(id, now_unix()); }, "complete step");
         }},
        {"journal.skip",
         [](const Json& a) {
             std::string id = require_string(a, "id");
             return journal_op(a, [&](InstallJournal& j) { return j.skip(id, now_unix()); }, "skip step");
         }},
        {"journal.fail",
         [](const Json& a) {
             std::string id = require_string(a, "id");
             std::string error = a["error"].string_or("unknown error");
             return journal_op(a, [&](InstallJournal& j) { return j.fail(id, error, now_unix()); }, "fail step");
         }},
        {"journal.reset_from",
         [](const Json& a) {
             std::string id = require_string(a, "id");
             return journal_op(a, [&](InstallJournal& j) { return j.reset_from(id); }, "reset");
         }},
        {"storage.decide",
         [](const Json& a) {
             StorageInputs in;
             in.host_free = u64(a, "host_free");
             in.disk_size = u64(a, "disk_size");
             in.disk_allocated = u64(a, "disk_allocated");
             in.fs_size = u64(a, "fs_size");
             in.fs_used = u64(a, "fs_used");
             in.host_reserve = u64(a, "host_reserve", in.host_reserve);
             in.max_disk = u64(a, "max_disk", in.max_disk);
             in.min_step = u64(a, "min_step", in.min_step);
             return decide_storage(in).to_json();
         }},
        {"storage.initial_size",
         [](const Json& a) {
             Json r = Json::object();
             r.set("size", initial_data_disk_size(u64(a, "host_free")));
             return r;
         }},
        {"storage.create_sparse",
         [](const Json& a) {
             if (!create_sparse_file(require_string(a, "path"), u64(a, "size")))
                 throw CallError{"cannot create sparse file"};
             return Json::object();
         }},
        {"storage.grow",
         [](const Json& a) {
             if (!grow_file(require_string(a, "path"), u64(a, "size"))) throw CallError{"cannot grow file"};
             return Json::object();
         }},
        {"storage.clone",
         [](const Json& a) {
             bool cow = false;
             if (!clone_file(require_string(a, "src"), require_string(a, "dst"), &cow))
                 throw CallError{"cannot clone file"};
             Json r = Json::object();
             r.set("cow", cow);
             return r;
         }},
        {"storage.usage",
         [](const Json& a) {
             const std::string& p = require_string(a, "path");
             Json r = Json::object();
             r.set("size", static_cast<long long>(file_size(p)));
             r.set("allocated", static_cast<long long>(allocated_size(p)));
             r.set("free", static_cast<long long>(free_space(p)));
             return r;
         }},
        {"file.sha256",
         [](const Json& a) {
             std::string hex;
             if (!sha256_file(require_string(a, "path"), hex)) throw CallError{"cannot hash file"};
             Json r = Json::object();
             r.set("sha256", hex);
             return r;
         }},
        {"control.request",
         [](const Json& a) {
             Json r = Json::object();
             r.set("line", make_request(a["id"].as_int(0), require_string(a, "op"), a["args"]));
             return r;
         }},
        {"control.parse",
         [](const Json& a) {
             ControlMessage m = parse_control_line(require_string(a, "line"));
             Json r = Json::object();
             switch (m.kind) {
                 case ControlMessage::Kind::Request:
                     r.set("kind", "request");
                     r.set("id", static_cast<long long>(m.id));
                     r.set("op", m.op);
                     r.set("args", m.args);
                     break;
                 case ControlMessage::Kind::Response:
                     r.set("kind", "response");
                     r.set("id", static_cast<long long>(m.id));
                     r.set("ok", m.ok);
                     r.set("result", m.result);
                     r.set("error", m.error);
                     break;
                 case ControlMessage::Kind::Event:
                     r.set("kind", "event");
                     r.set("event", m.event);
                     r.set("data", m.data);
                     break;
                 case ControlMessage::Kind::Invalid:
                     r.set("kind", "invalid");
                     r.set("error", m.error);
                     break;
             }
             return r;
         }},
        {"compat.lookup",
         [](const Json& a) {
             CompatDatabase db;
             std::string err;
             if (!db.load_json(require_string(a, "db"), &err)) throw CallError{"compat db: " + err};
             const CompatEntry* e = db.find(static_cast<uint32_t>(a["appid"].as_int(0)));
             if (!e) return Json();
             Json r = Json::object();
             r.set("appid", e->appid);
             r.set("name", e->name);
             r.set("path", e->path);
             r.set("status", compat_status_name(e->status));
             r.set("fps_avg", e->fps_avg);
             r.set("notes", e->notes);
             r.set("tested_at", e->tested_at);
             r.set("runtime_version", e->runtime_version);
             r.set("launch_options", e->launch_options);
             return r;
         }},
    };
    return h;
}

struct Framer {
    LineFramer f;
};

}  // namespace

extern "C" {

const char* ideck_core_version(void) { return kVersion; }

char* ideck_call(const char* method, const char* args_json) {
    Json reply = Json::object();
    try {
        if (!method) throw CallError{"method is required"};
        Json args = Json::object();
        if (args_json && *args_json) {
            std::string perr;
            if (!Json::parse(args_json, args, &perr)) throw CallError{"arguments are not valid JSON: " + perr};
        }
        auto it = handlers().find(method);
        if (it == handlers().end()) throw CallError{std::string("unknown method '") + method + "'"};
        reply.set("ok", true);
        reply.set("result", it->second(args));
    } catch (const CallError& e) {
        reply = Json::object();
        reply.set("ok", false);
        reply.set("error", e.message);
    } catch (const std::exception& e) {
        reply = Json::object();
        reply.set("ok", false);
        reply.set("error", std::string("internal error: ") + e.what());
    }
    return dup_string(reply.dump());
}

void ideck_free(char* p) { std::free(p); }

struct ideck_sha256 {
    Sha256 h;
};

ideck_sha256* ideck_sha256_new(void) { return new ideck_sha256(); }

void ideck_sha256_update(ideck_sha256* h, const void* data, size_t len) {
    if (h && data && len) h->h.update(data, len);
}

void ideck_sha256_finish(ideck_sha256* h, char* out) {
    if (!h) return;
    auto d = h->h.finish();
    std::string hex = to_hex(d.data(), d.size());
    if (out) std::memcpy(out, hex.c_str(), hex.size() + 1);
    delete h;
}

struct ideck_sparse {
    SparseWriter w{4096};
};

ideck_sparse* ideck_sparse_open(const char* path) {
    if (!path) return nullptr;
    auto* s = new ideck_sparse();
    if (!s->w.open(path)) {
        delete s;
        return nullptr;
    }
    return s;
}

int ideck_sparse_write(ideck_sparse* w, const void* data, size_t len) {
    if (!w) return 0;
    return w->w.write(data, len) ? 1 : 0;
}

int ideck_sparse_finish(ideck_sparse* w, uint64_t* bytes_skipped) {
    if (!w) return 0;
    bool ok = w->w.finish();
    if (bytes_skipped) *bytes_skipped = w->w.bytes_skipped();
    delete w;
    return ok ? 1 : 0;
}

void ideck_sparse_abort(ideck_sparse* w) { delete w; }

void ideck_input_encode(const ideck_pad_state* s, uint8_t out[32]) {
    InputPacket p;
    if (s) {
        p.type = static_cast<InputType>(s->type);
        p.pad = s->pad > 3 ? 3 : s->pad;
        p.kind = static_cast<PadKind>(s->kind <= 3 ? s->kind : 0);
        p.seq = s->seq;
        p.buttons = s->buttons;
        p.lx = axis_to_i16(s->lx);
        p.ly = axis_to_i16(s->ly);
        p.rx = axis_to_i16(s->rx);
        p.ry = axis_to_i16(s->ry);
        p.lt = trigger_to_u16(s->lt);
        p.rt = trigger_to_u16(s->rt);
    }
    encode_input(p, out);
}

struct ideck_input_decoder {
    InputStreamDecoder d;
};

ideck_input_decoder* ideck_input_decoder_new(void) { return new ideck_input_decoder(); }

size_t ideck_input_decoder_feed(ideck_input_decoder* d, const uint8_t* data, size_t len, ideck_rumble* out,
                                size_t max) {
    if (!d || !data) return 0;
    size_t n = 0;
    for (const auto& p : d->d.feed(data, len)) {
        if (p.type != InputType::Rumble) continue;
        if (n >= max || !out) break;
        out[n].pad = p.pad;
        out[n].strong = p.rumble_strong;
        out[n].weak = p.rumble_weak;
        out[n].duration_ms = p.rumble_ms;
        ++n;
    }
    return n;
}

void ideck_input_decoder_free(ideck_input_decoder* d) { delete d; }

struct ideck_framer {
    LineFramer f;
};

ideck_framer* ideck_framer_new(void) { return new ideck_framer(); }

char* ideck_framer_feed(ideck_framer* f, const char* data, size_t len) {
    Json arr = Json::array();
    if (f && data) {
        for (auto& line : f->f.feed(std::string_view(data, len))) arr.push(std::move(line));
    }
    return dup_string(arr.dump());
}

void ideck_framer_free(ideck_framer* f) { delete f; }

}  // extern "C"
