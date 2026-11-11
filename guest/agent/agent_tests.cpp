// Host-runnable tests for the agent's pure parsing and mapping logic.
#include "../../core/tests/testing.hpp"
#include "gamepad.hpp"
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

TEST("agent: cpu usage between samples") {
    std::vector<CpuTimes> a = {{100, 1000}, {50, 500}};
    std::vector<CpuTimes> b = {{150, 1100}, {50, 600}};
    auto u = cpu_usage(a, b);
    CHECK_EQ(u.size(), 2u);
    CHECK_EQ(u[0], 50.0);
    CHECK_EQ(u[1], 0.0);
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
