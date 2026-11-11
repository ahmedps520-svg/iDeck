// iDeck core — QEMU command line construction.
//
// One function turns a VM configuration into the argv passed to
// qemu_init(). The iOS profile targets the utmapp/qemu fork (TCG + SPICE +
// virtio-gpu Venus); the desktop-test profile targets stock QEMU on CI
// runners so the same guest image and agent can be boot-tested headless.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "ideck/json.hpp"

namespace ideck {

enum class QemuProfile { IOS, DesktopTest };

struct VmConfig {
    QemuProfile profile = QemuProfile::IOS;

    // Runtime files.
    std::string kernel;
    std::string initrd;          // optional
    std::string system_disk;
    std::string data_disk;
    std::vector<std::string> extra_disks;  // external library images
    std::string cmdline;

    // CPU / memory.
    uint64_t guest_mb = 3072;
    int cpus = 4;
    uint64_t tb_cache_mb = 384;
    std::string cpu_model = "neoverse-n1";
    bool multithread_tcg = true;
    // JIT obtained through a debugger on TXM devices maps code through a
    // RW/RX mirror (QEMU split-wx). Required unless the app holds the
    // dynamic-codesigning entitlement (it never does when sideloaded).
    bool split_wx = true;
    // Back guest RAM with a file instead of anonymous memory so dirty pages
    // can be written back instead of counting toward the jetsam footprint.
    std::string ram_file;

    // Graphics.
    bool gl = true;
    bool vulkan = true;
    uint64_t hostmem_mb = 2048;
    int width = 1280;
    int height = 720;
    int refresh_hz = 60;

    // Channels (unix sockets, QEMU listens).
    std::string spice_socket;
    std::string qmp_socket;
    std::string control_socket;   // guest agent JSON channel
    std::string input_socket;     // guest agent binary input channel
    std::string console_log;      // serial console file

    std::string audio = "hda";    // hda | virtio | none
    bool balloon = true;
    std::string mac = "52:54:00:1d:ec:01";
    bool usb_input = true;        // xHCI tablet/mouse/keyboard for SPICE input
};

struct QemuArgsResult {
    bool ok = false;
    std::vector<std::string> argv;  // argv[0] = "qemu-system-aarch64"
    std::vector<std::string> errors;
    std::vector<std::string> warnings;
};

// sockaddr_un.sun_path is 104 bytes on Darwin (including the NUL).
constexpr size_t kMaxUnixSocketPath = 103;

QemuArgsResult build_qemu_args(const VmConfig& cfg);

bool vm_config_from_json(const Json& j, VmConfig& out, std::string* err = nullptr);
Json vm_config_to_json(const VmConfig& cfg);

// Kernel command line used for the iDeck guest unless the manifest overrides.
std::string default_kernel_cmdline();

}  // namespace ideck
