// Host-runnable tests for the agent's pure parsing and mapping logic.
#include "../../core/tests/testing.hpp"
#include "gamepad.hpp"
#include "steam_ui.hpp"
#include "sysinfo.hpp"

using namespace agent;

TEST("agent: meminfo parsing") {
    MemInfo m = parse_meminfo(
        "MemTotal:        4018412 kB\nMemFree:          112000 kB\nMemAvailable:    2900000 kB\n"
        "Buffers:            1000 kB\nCached:          1500000 kB\nSwapTotal:             0 kB\n"
        "SwapFree:              0 kB\n");
    CHECK_EQ(m.total_kb, 4018412u);
    CHECK_EQ(m.available_kb, 2900000u);
    CHECK_EQ(m.cached_kb, 1500000u);
}

TEST("agent: os-release and cpu features") {
    ideck::Json os = parse_os_release(
        "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nNAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\n"
        "VERSION_CODENAME=trixie\nID=debian\n");
    CHECK_EQ(os["ID"].as_string(), std::string("debian"));
    CHECK_EQ(os["VERSION_ID"].as_string(), std::string("13"));
    CHECK_EQ(os["PRETTY_NAME"].as_string(), std::string("Debian GNU/Linux 13 (trixie)"));
    auto f = parse_cpu_features(
        "processor\t: 0\nBogoMIPS\t: 125.00\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics "
        "fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp\nCPU implementer\t: 0x41\n");
    CHECK_EQ(f.size(), 16u);
    CHECK_EQ(f[8], std::string("atomics"));
}

TEST("agent: kernel log line lookup") {
    std::string klog =
        "<6>[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x414fd0c1]\n"
        "<6>[    0.000000] CPU features: kernel page table isolation forced ON by KASLR\n"
        "<6>[    0.012000] smp: Bringing up secondary CPUs ...\n";
    CHECK_EQ(find_log_line(klog, "kernel page table isolation"),
             std::string("CPU features: kernel page table isolation forced ON by KASLR"));
    CHECK_EQ(find_log_line("[    0.1] last line without newline", "last line"),
             std::string("last line without newline"));
    CHECK(find_log_line(klog, "not there").empty());
    CHECK_EQ(trimmed("root=/dev/vda kpti=0\n"), std::string("root=/dev/vda kpti=0"));
}

TEST("agent: cpu usage between samples") {
    std::vector<CpuTimes> a = {{100, 1000}, {50, 500}};
    std::vector<CpuTimes> b = {{150, 1100}, {50, 600}};
    auto u = cpu_usage(a, b);
    CHECK_EQ(u.size(), 2u);
    CHECK_EQ(u[0], 50.0);
    CHECK_EQ(u[1], 0.0);
}

TEST("agent: /proc/<pid>/stat and status parsing") {
    ProcStat st;
    // A command name with spaces and parentheses (fields after it as in Linux 6.12).
    CHECK(parse_proc_stat(
        "1234 (Web Content (x)) S 1 1234 1234 0 -1 4194560 5000 0 12 0 750 250 0 0 20 5 31 0 900 "
        "123456789 2048 18446744073709551615 1 1 0 0 0 0 0 4096 0 0 0 0 17 2 0 0 0 0 0",
        st));
    CHECK_EQ(st.comm, std::string("Web Content (x)"));
    CHECK_EQ(st.ticks, 1000u);
    CHECK_EQ(st.nice, 5);
    CHECK_EQ(st.threads, 31);
    CHECK_EQ(st.rss_pages, 2048u);
    CHECK(!parse_proc_stat("1234 (truncated) S 1 2", st));
    CHECK(!parse_proc_stat("garbage", st));

    std::string status = "Name:\tsteamwebhelper\nCpus_allowed:\t0c\nCpus_allowed_list:\t2-3\nThreads:\t40\n";
    CHECK_EQ(status_value(status, "Cpus_allowed_list"), std::string("2-3"));
    CHECK_EQ(status_value(status, "Cpus_allowed"), std::string("0c"));
    CHECK_EQ(status_value(status, "Name"), std::string("steamwebhelper"));
    CHECK(status_value(status, "Missing").empty());
}

TEST("agent: Steam UI helpers") {
    auto ids = parse_window_ids("12582913\n12582919\n\nnot-an-id\n 4194305 \n");
    CHECK_EQ(ids.size(), 3u);
    CHECK_EQ(ids[0], std::string("12582913"));
    CHECK_EQ(ids[2], std::string("4194305"));
    CHECK(parse_window_ids("").empty());

    using namespace std::string_literals;
    CHECK(is_game_launch_cmdline("/home/deck/.local/share/Steam/steamrtarm64/reaper\0SteamLaunch\0AppId=1794680\0--\0game\0"s));
    CHECK(!is_game_launch_cmdline("/usr/bin/pgrep\0-f\0SteamLaunch AppId=\0"s));  // the pattern as one argument
    CHECK(!is_game_launch_cmdline("reaper\0SteamLaunch\0AppId=\0"s));             // no app id
    CHECK(!is_game_launch_cmdline("steamwebhelper\0--type=renderer\0"s));

    CHECK_EQ(webhelper_nice_for("visible", false), 0);
    CHECK_EQ(webhelper_nice_for("visible", true), 19);
    CHECK_EQ(webhelper_nice_for("away", false), 19);
    CHECK_EQ(webhelper_nice_for("game", false), 19);

    auto argv = xdotool_chain("windowminimize", {"1", "2"});
    CHECK_EQ(argv.size(), 7u);
    CHECK_EQ(argv[1], std::string("DISPLAY=:0"));
    CHECK_EQ(argv[3], std::string("windowminimize"));
    CHECK_EQ(argv[6], std::string("2"));

    CHECK_EQ(chromium_process_type("/home/deck/.local/share/Steam/steamrtarm64/steamwebhelper\0--type=gpu-process\0--no-sandbox\0"s),
             std::string("gpu-process"));
    CHECK_EQ(chromium_process_type("steamwebhelper\0-lang=en_US\0"s), std::string("browser"));
    auto libs = graphics_libraries(
        "ffff8000-ffff9000 r-xp 00000000 fe:00 1 /usr/lib/aarch64-linux-gnu/libgallium-26.1.6-1~bpo13+1.so\n"
        "ffff9000-ffffa000 r-xp 00000000 fe:00 2 /usr/lib/aarch64-linux-gnu/libvulkan_virtio.so\n");
    CHECK_EQ(libs.size(), 2u);
    CHECK_EQ(libs[0], std::string("libvulkan_virtio"));
    CHECK(graphics_libraries("ffff0000-ffff1000 r-xp 0 fe:00 3 /usr/lib/libc.so.6\n").empty());

    // Without its thread (not started here) a request returns the last status.
    SteamUi ui;
    CHECK(ui.request("away", 10).is_object());
}

TEST("agent: fpcheck comparison with the hardware reference") {
    using ideck::Json;
    Json ref, same, other, none;
    CHECK(Json::parse(R"({"patterns": {"FADD_s": ["a1", "f1"], "FCMP": ["a2", "f2"]},
        "mix_values": "m", "mix_flags": "g", "cpu": "Neoverse-N2"})", ref));
    CHECK(Json::parse(R"({"patterns": {"FADD_s": ["a1", "f1"], "FCMP": ["a2", "f2"]},
        "mix_values": "m", "mix_flags": "g", "sigill": [], "runs": 10, "seconds": 1.5})", same));
    Json r = agent::fpcheck_compare(same, ref);
    CHECK(r["match"].as_bool());
    CHECK(r["flags_match"].as_bool());
    CHECK_EQ(r["patterns"].as_int(), 2);
    CHECK_EQ(r["reference_cpu"].as_string(), std::string("Neoverse-N2"));
    // A different value digest fails the match; a flag digest only flags_match.
    CHECK(Json::parse(R"({"patterns": {"FADD_s": ["XX", "f1"], "FCMP": ["a2", "YY"]},
        "mix_values": "m", "mix_flags": "g", "sigill": []})", other));
    r = agent::fpcheck_compare(other, ref);
    CHECK(!r["match"].as_bool());
    CHECK(!r["flags_match"].as_bool());
    CHECK_EQ(r["values_differ"].as_int(), 1);
    CHECK_EQ(r["values_differ_names"].at(0).as_string(), std::string("FADD_s"));
    CHECK_EQ(r["flags_differ_names"].at(0).as_string(), std::string("FCMP"));
    // A pattern that did not run, a SIGILL, or no reference: no match.
    CHECK(Json::parse(R"({"patterns": {"FADD_s": ["a1", "f1"]}, "mix_values": "m", "mix_flags": "g"})", other));
    CHECK(!agent::fpcheck_compare(other, ref)["match"].as_bool());
    CHECK(Json::parse(R"({"patterns": {"FADD_s": ["a1", "f1"], "FCMP": ["a2", "f2"]},
        "mix_values": "m", "mix_flags": "g", "sigill": ["FCMP"]})", other));
    CHECK(!agent::fpcheck_compare(other, ref)["match"].as_bool());
    r = agent::fpcheck_compare(same, none);
    CHECK(!r["match"].as_bool());
    CHECK(!r["reference"].as_bool());
}

#if defined(__linux__)
#include <linux/input.h>
TEST("agent: gamepad state maps to evdev events") {
    ideck::InputPacket a, b;
    b.buttons = ideck::kBtnA | ideck::kBtnDpadUp;
    b.ly = 32767;   // stick fully up on the host
    b.lt = 65535;
    auto ev = pad_events(a, b);
    bool saw_a = false, saw_up = false, saw_y = false, saw_lt = false;
    for (const auto& e : ev) {
        if (e.type == EV_KEY && e.code == BTN_SOUTH && e.value == 1) saw_a = true;
        if (e.type == EV_ABS && e.code == ABS_HAT0Y && e.value == -1) saw_up = true;
        if (e.type == EV_ABS && e.code == ABS_Y && e.value == -32767) saw_y = true;
        if (e.type == EV_ABS && e.code == ABS_Z && e.value == 255) saw_lt = true;
    }
    CHECK(saw_a);
    CHECK(saw_up);
    CHECK(saw_y);
    CHECK(saw_lt);
    CHECK(pad_events(b, b).empty());
}
#endif
