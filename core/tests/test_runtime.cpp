// Tests: manifest, journal, memory planner, storage policy, compat db.
#include <chrono>
#include <filesystem>
#include <string>

#include "ideck/compat.hpp"
#include "ideck/fsutil.hpp"
#include "ideck/journal.hpp"
#include "ideck/manifest.hpp"
#include "ideck/memory_planner.hpp"
#include "ideck/storage.hpp"
#include "testing.hpp"

using namespace ideck;
namespace fs = std::filesystem;

namespace {

const char* kHash1 = "1111111111111111111111111111111111111111111111111111111111111111";
const char* kHash2 = "2222222222222222222222222222222222222222222222222222222222222222";

std::string sample_manifest(const std::string& kernel_url = "https://example.org/Image.xz") {
    return std::string(R"({
      "schema": 1,
      "runtime_version": "0.1.0",
      "channel": "stable",
      "min_app_build": 1,
      "kernel_cmdline": "root=/dev/vda",
      "guest": {"distro": "debian-13"},
      "artifacts": [
        {"id":"kernel","role":"kernel","file":"Image","url":")") + kernel_url + R"(",
         "sha256":")" + kHash1 + R"(","size":100,"compression":"xz","installed_size":300,
         "installed_sha256":")" + kHash2 + R"("},
        {"id":"system","role":"system-disk","file":"system.img","url":"https://example.org/system.img",
         "sha256":")" + kHash2 + R"(","size":5000,"sparse":true}
      ]})";
}

std::string temp_dir(const char* tag) {
    auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    auto p = fs::temp_directory_path() / (std::string("ideck-test-") + tag + "-" + std::to_string(stamp));
    fs::create_directories(p);
    return p.string();
}

}  // namespace

TEST("versions: numeric ordering") {
    CHECK(compare_versions("1.10.0", "1.9.9") > 0);
    CHECK(compare_versions("v2.0", "2") == 0);
    CHECK(compare_versions("0.1.0-beta", "0.1.0") == 0);
    CHECK(compare_versions("0.1", "0.1.1") < 0);
}

TEST("manifest: accepts a valid manifest") {
    Manifest m;
    std::vector<std::string> errors;
    CHECK(parse_manifest(sample_manifest(), m, errors));
    CHECK(errors.empty());
    CHECK_EQ(m.artifacts.size(), 2u);
    CHECK(m.find_role("kernel") != nullptr);
    CHECK(m.find_role("system-disk")->sparse);
    CHECK_EQ(m.total_download_size(), 5100u);
    CHECK_EQ(m.total_installed_size(), 5300u);
}

TEST("manifest: rejects insecure or unsafe artifacts") {
    Manifest m;
    std::vector<std::string> errors;
    CHECK(!parse_manifest(sample_manifest("http://example.org/Image.xz"), m, errors));
    CHECK(!errors.empty());

    std::string bad_name = sample_manifest();
    bad_name.replace(bad_name.find("\"file\":\"Image\""), 14, "\"file\":\"../x\"");
    CHECK(!parse_manifest(bad_name, m, errors));

    std::string bad_hash = sample_manifest();
    bad_hash.replace(bad_hash.find(kHash1), 64, std::string(64, 'Z'));
    CHECK(!parse_manifest(bad_hash, m, errors));

    CHECK(!parse_manifest("{\"schema\":2}", m, errors));
    CHECK(!parse_manifest("not json", m, errors));
    CHECK(is_safe_file_name("system.img"));
    CHECK(!is_safe_file_name(".hidden"));
    CHECK(!is_safe_file_name("a/b"));
}

TEST("journal: steps run in order and persist") {
    std::string dir = temp_dir("journal");
    std::string path = dir + "/install.json";
    InstallJournal j(InstallJournal::default_steps());
    CHECK_EQ(j.next()->id, std::string("check-device"));
    CHECK(!j.begin("download-runtime", 1));  // out of order
    CHECK(j.begin("check-device", 1));
    CHECK(j.complete("check-device", 2));
    CHECK(j.begin("check-storage", 3));
    CHECK(j.save(path));

    // Simulate the app being killed while "check-storage" was running.
    InstallJournal k(InstallJournal::default_steps());
    CHECK(k.load(path));
    CHECK(k.find("check-storage")->state == StepState::Running);
    CHECK_EQ(k.recover_interrupted(), 1);
    CHECK_EQ(k.find("check-storage")->state == StepState::Pending, true);
    CHECK_EQ(k.find("check-storage")->attempts, 1);
    CHECK_EQ(k.next()->id, std::string("check-storage"));
    CHECK(k.begin("check-storage", 4));
    CHECK(k.fail("check-storage", "not enough space", 5));
    CHECK(k.has_failure());
    CHECK(k.begin("check-storage", 6));  // retry after failure
    CHECK_EQ(k.find("check-storage")->attempts, 3);
    CHECK(k.complete("check-storage", 7));
    CHECK(k.progress() > 0.1);
    remove_path(dir);
}

TEST("journal: done steps after a gap are invalidated; reset rolls back") {
    InstallJournal j(InstallJournal::default_steps());
    Json saved = j.to_json();
    // Hand-craft a journal where a later step claims done but an earlier is not.
    Json steps = Json::array();
    for (const auto& s : saved["steps"].items()) {
        Json c = s;
        if (s["id"].as_string() == "verify-runtime") c.set("state", "done");
        steps.push(c);
    }
    saved.set("steps", steps);
    CHECK(j.from_json(saved));
    CHECK(j.find("verify-runtime")->state == StepState::Pending);

    for (const auto& s : InstallJournal::default_steps()) {
        CHECK(j.begin(s.id, 1));
        CHECK(j.complete(s.id, 2));
    }
    CHECK(j.is_complete());
    CHECK(j.reset_from("install-steam"));
    CHECK(!j.is_complete());
    CHECK_EQ(j.next()->id, std::string("install-steam"));
    CHECK(j.find("boot-guest")->state == StepState::Done);
}

TEST("memory: 12 GB iPad with a 6 GB limit gets 3 GiB") {
    MemoryInputs in;
    in.physical_mb = 12288;
    in.app_limit_mb = 6144;
    in.increased_memory_limit = true;
    in.cpus = 4;
    MemoryPlan p = plan_memory(in);
    CHECK(p.fits);
    CHECK_EQ(p.guest_mb, 3072u);
    CHECK_EQ(p.tb_cache_mb, 384u);
    CHECK(p.guest_mb + p.tb_cache_mb + p.gpu_budget_mb + p.overhead_mb <= 6144u);
}

TEST("memory: measured M5 limit (5120 MiB) gives a 3 GiB guest") {
    // From the first device run: iPad17,2, iPadOS 27.2, 5110 MiB available
    // at launch with a 9 MiB footprint.
    MemoryInputs in;
    in.physical_mb = 12288;
    in.app_limit_mb = 5120;
    in.cpus = 4;
    MemoryPlan p = plan_memory(in);
    CHECK(p.fits);
    CHECK_EQ(p.guest_mb, 3072u);
    CHECK(p.guest_mb + p.tb_cache_mb + p.gpu_budget_mb + p.overhead_mb <= 5120u);
}

TEST("memory: larger limits unlock larger tiers; entitlement gates >4 GiB") {
    MemoryInputs in;
    in.physical_mb = 12288;
    in.app_limit_mb = 8192;
    in.cpus = 4;
    in.increased_memory_limit = true;
    CHECK_EQ(plan_memory(in).guest_mb, 5120u);
    in.increased_memory_limit = false;
    CHECK_EQ(plan_memory(in).guest_mb, 4096u);
    in.app_limit_mb = 2000;
    MemoryPlan tiny = plan_memory(in);
    CHECK(!tiny.fits);
    CHECK_EQ(tiny.guest_mb, 2048u);
}

TEST("memory: user override honoured only when it fits") {
    MemoryInputs in;
    in.physical_mb = 12288;
    in.app_limit_mb = 8192;
    in.increased_memory_limit = true;
    in.user_guest_mb = 2048;
    CHECK_EQ(plan_memory(in).guest_mb, 2048u);
    in.user_guest_mb = 6144;
    MemoryPlan p = plan_memory(in);
    CHECK_EQ(p.guest_mb, 5120u);
    CHECK(!p.notes.empty());
}

TEST("memory: unknown limit is estimated conservatively") {
    MemoryInputs in;
    in.physical_mb = 12288;
    in.increased_memory_limit = true;
    MemoryPlan p = plan_memory(in);
    CHECK_EQ(p.limit_mb, 6144u);
    CHECK_EQ(p.guest_mb, 3072u);
}

TEST("memory: pressure actions") {
    PressureActions n = pressure_actions(PressureLevel::Normal, 4096, 1000);
    CHECK_EQ(n.balloon_target_mb, 4096u);
    CHECK(!n.drop_guest_caches);
    PressureActions w = pressure_actions(PressureLevel::Warning, 4096, 1000);
    CHECK(w.drop_guest_caches);
    CHECK_EQ(w.balloon_target_mb, 2048u);  // floor at half
    PressureActions c = pressure_actions(PressureLevel::Critical, 4096, 3000);
    CHECK_EQ(c.balloon_target_mb, 3256u);
    CHECK(c.flush_disks);
    CHECK(c.notify_user);
}

TEST("storage: grows when nearly full, respects reserve and cap") {
    const uint64_t G = 1ull << 30;
    StorageInputs in;
    in.host_free = 100 * G;
    in.disk_size = 24 * G;
    in.fs_size = 24 * G;
    in.fs_used = 10 * G;
    CHECK(!decide_storage(in).grow);
    in.fs_used = 22 * G;
    StorageDecision d = decide_storage(in);
    CHECK(d.grow);
    CHECK_EQ(d.new_size, 40 * G);  // +16 GiB minimum step
    in.host_free = 12 * G;         // only 4 GiB above the 8 GiB reserve
    d = decide_storage(in);
    CHECK(d.grow);
    CHECK_EQ(d.new_size, 28 * G);
    in.host_free = 8 * G;
    d = decide_storage(in);
    CHECK(!d.grow);
    CHECK(d.guest_full);
    CHECK(d.host_low == false);
    in.host_free = 2 * G;
    CHECK(decide_storage(in).host_low);
    in.host_free = 500 * G;
    in.disk_size = 200 * G;
    in.fs_size = 200 * G;
    in.fs_used = 199 * G;
    CHECK(decide_storage(in).guest_full);
    CHECK_EQ(initial_data_disk_size(200 * G), 24 * G);
    CHECK_EQ(initial_data_disk_size(10 * G), 8 * G);
}

TEST("compat: results must carry provenance") {
    CompatDatabase db;
    std::string err;
    CHECK(db.load_json(R"({"schema":1,"games":[{"appid":70,"name":"Half-Life","path":"windows","status":"untested"}]})", &err));
    CHECK(db.find(70) != nullptr);
    CHECK(db.find(71) == nullptr);
    CHECK(!db.load_json(R"({"schema":1,"games":[{"appid":70,"name":"x","path":"windows","status":"playable"}]})", &err));
    CHECK(!db.load_json(R"({"schema":1,"games":[{"appid":70,"name":"x","path":"psx","status":"untested"}]})", &err));
    CompatEntry e;
    e.appid = 70;
    e.name = "Half-Life";
    e.path = "windows";
    e.status = CompatStatus::Boots;
    e.tested_at = "2026-11-11";
    e.runtime_version = "0.1.0";
    db.upsert(e);
    CompatDatabase back;
    CHECK(back.load_json(db.dump(), &err));
    CHECK(back.find(70)->status == CompatStatus::Boots);
}
