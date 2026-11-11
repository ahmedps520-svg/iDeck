#include "ideck/qemu_args.hpp"

#include <algorithm>

namespace ideck {

namespace {

// QEMU option values use ',' as a separator; a literal comma is written ",,".
std::string qopt(const std::string& v) {
    std::string out;
    out.reserve(v.size());
    for (char c : v) {
        out.push_back(c);
        if (c == ',') out.push_back(',');
    }
    return out;
}

void check_socket(const std::string& what, const std::string& path, QemuArgsResult& r) {
    if (path.empty()) return;
    if (path.size() > kMaxUnixSocketPath) {
        r.errors.push_back(what + " socket path is " + std::to_string(path.size()) +
                           " bytes; the limit is " + std::to_string(kMaxUnixSocketPath));
    }
}

bool valid_cpu_model(const std::string& m) {
    static const char* allowed[] = {"neoverse-n1", "neoverse-v1", "neoverse-n2", "cortex-a76",
                                    "cortex-a710", "max", "cortex-a72"};
    std::string base = m.substr(0, m.find(','));
    for (const char* a : allowed) {
        if (base == a) return true;
    }
    return false;
}

}  // namespace

std::string default_kernel_cmdline() {
    // root is the system disk (whole-disk ext4, no partition table).
    // ideck.* parameters are read by the guest provisioning service.
    return "root=/dev/vda rootfstype=ext4 rw console=ttyAMA0 loglevel=4 "
           "systemd.show_status=auto rd.udev.log_level=3 quiet "
           "transparent_hugepage=never ideck.mode=gaming";
}

QemuArgsResult build_qemu_args(const VmConfig& c) {
    QemuArgsResult r;
    auto& a = r.argv;
    auto add = [&](std::initializer_list<std::string> items) {
        for (const auto& i : items) a.push_back(i);
    };

    if (c.kernel.empty()) r.errors.push_back("kernel path is required");
    if (c.system_disk.empty()) r.errors.push_back("system disk path is required");
    if (c.guest_mb < 1024) r.errors.push_back("guest memory must be at least 1024 MiB");
    if (c.cpus < 1 || c.cpus > 8) r.errors.push_back("cpus must be between 1 and 8");
    if (!valid_cpu_model(c.cpu_model)) r.errors.push_back("unsupported cpu model '" + c.cpu_model + "'");
    if (c.width < 640 || c.height < 360 || c.width > 3840 || c.height > 2160)
        r.errors.push_back("resolution out of range");
    if (c.vulkan && !c.gl) r.errors.push_back("Venus (vulkan) requires the GL virtio-gpu device");
    if (c.audio != "hda" && c.audio != "virtio" && c.audio != "none")
        r.errors.push_back("audio must be hda, virtio or none");
    check_socket("SPICE", c.spice_socket, r);
    check_socket("QMP", c.qmp_socket, r);
    check_socket("control", c.control_socket, r);
    check_socket("input", c.input_socket, r);
    if (c.profile == QemuProfile::IOS && c.spice_socket.empty())
        r.errors.push_back("the iOS profile needs a SPICE socket for display and input");
    if (c.cpu_model == "cortex-a72")
        r.warnings.push_back("cortex-a72 lacks LSE atomics; the ARM64 Steam client needs ARMv8.1+");
    if (!r.errors.empty()) return r;

    const bool ios = c.profile == QemuProfile::IOS;

    a.push_back("qemu-system-aarch64");
    add({"-name", "iDeck,debug-threads=on"});
    a.push_back("-nodefaults");
    add({"-no-user-config"});

    // Machine. Direct kernel boot: no firmware, fastest path to userspace.
    std::string machine = "virt,gic-version=3,highmem=on";
    if (!c.ram_file.empty()) machine += ",memory-backend=ram0";
    add({"-machine", machine});
    if (!c.ram_file.empty()) {
        add({"-object", "memory-backend-file,id=ram0,size=" + std::to_string(c.guest_mb) +
                            "M,mem-path=" + qopt(c.ram_file) + ",share=on,prealloc=off"});
    }

    std::string accel = "tcg";
    if (c.multithread_tcg) accel += ",thread=multi";
    accel += ",tb-size=" + std::to_string(c.tb_cache_mb);
    if (ios && c.split_wx) accel += ",split-wx=on";
    add({"-accel", accel});

    std::string cpu = c.cpu_model;
    if (cpu == "max") {
        // Pointer authentication and SVE/SME are costly to emulate and not
        // needed by the guest userspace; FEX uses NEON paths without SVE.
        cpu += ",pauth=off,sve=off,sme=off";
    }
    add({"-cpu", cpu});
    add({"-smp", "cpus=" + std::to_string(c.cpus) + ",sockets=1,cores=" + std::to_string(c.cpus) +
                     ",threads=1"});
    add({"-m", std::to_string(c.guest_mb) + "M"});

    add({"-kernel", c.kernel});
    if (!c.initrd.empty()) add({"-initrd", c.initrd});
    add({"-append", c.cmdline.empty() ? default_kernel_cmdline() : c.cmdline});

    add({"-rtc", "base=utc,clock=host"});
    add({"-device", "virtio-rng-pci"});

    // Disks: raw images, created sparse. On the iPad, discard fails for
    // every request ("I/O error, dev vdb ... op 0x3:(DISCARD)" during mkfs
    // on device), so it is not offered to the guest there; the desktop test
    // profile keeps it to keep CI images sparse.
    const std::string discard = ios ? "discard=ignore,detect-zeroes=off" : "discard=unmap,detect-zeroes=unmap";
    auto disk = [&](const std::string& id, const std::string& path, const std::string& serial) {
        add({"-drive", "if=none,id=" + id + ",file=" + qopt(path) +
                           ",format=raw,cache=writeback,aio=threads," + discard + ",file.locking=off"});
        add({"-device", "virtio-blk-pci,drive=" + id + ",serial=" + serial});
    };
    disk("sys", c.system_disk, "ideck-system");
    if (!c.data_disk.empty()) disk("data", c.data_disk, "ideck-data");
    for (size_t i = 0; i < c.extra_disks.size(); ++i) {
        disk("ext" + std::to_string(i), c.extra_disks[i], "ideck-ext" + std::to_string(i));
    }

    // Network: user-mode (slirp); the only option inside the iOS sandbox.
    add({"-netdev", "user,id=net0"});
    add({"-device", "virtio-net-pci,netdev=net0,mac=" + c.mac + ",romfile="});

    // Graphics.
    if (ios && c.gl) {
        std::string gpu = "virtio-gpu-gl-pci,id=gpu0,xres=" + std::to_string(c.width) +
                          ",yres=" + std::to_string(c.height);
        if (c.vulkan) {
            gpu += ",blob=true,venus=true,hostmem=" + std::to_string(c.hostmem_mb) + "M";
        }
        // No refresh_rate: the utmapp/qemu 10.0.12 virtio-gpu-gl-pci device
        // rejects it ("Property ... not found", seen on device); the guest
        // display defaults to 60 Hz.
        add({"-device", gpu});
    } else {
        add({"-device", "virtio-gpu-pci,id=gpu0,xres=" + std::to_string(c.width) +
                            ",yres=" + std::to_string(c.height)});
        if (!ios && c.gl) r.warnings.push_back("desktop-test profile renders without host GL");
    }

    if (ios) {
        std::string spice = "unix=on,addr=" + qopt(c.spice_socket) +
                            ",disable-ticketing=on,image-compression=off,playback-compression=off,"
                            "streaming-video=off";
        spice += c.gl ? ",gl=on" : ",gl=off";
        add({"-spice", spice});
    } else {
        add({"-display", "none"});
    }

    // Audio: SPICE playback channel on iOS (CocoaSpice plays it through
    // AVAudioEngine); discarded on headless test hosts.
    if (c.audio != "none") {
        add({"-audiodev", ios ? "spice,id=audio0" : "none,id=audio0"});
        if (c.audio == "hda") {
            add({"-device", "intel-hda"});
            add({"-device", "hda-duplex,audiodev=audio0"});
        } else {
            add({"-device", "virtio-sound-pci,audiodev=audio0"});
        }
    }

    // Pointer/keyboard: SPICE input is delivered to these devices. The
    // tablet gives absolute touch positions; the mouse gives relative motion
    // for games that capture the pointer.
    if (c.usb_input) {
        add({"-device", "nec-usb-xhci,id=usb-bus"});
        add({"-device", "usb-tablet,bus=usb-bus.0"});
        add({"-device", "usb-mouse,bus=usb-bus.0"});
        add({"-device", "usb-kbd,bus=usb-bus.0"});
    }

    // Guest agent channels. On iOS the SPICE agent channel is added too:
    // spice-vdagent in the guest follows the iPad view size and syncs the
    // clipboard.
    if (ios || !c.control_socket.empty() || !c.input_socket.empty()) {
        add({"-device", "virtio-serial-pci,id=vser0"});
        if (ios) {
            add({"-chardev", "spicevmc,id=vdagent0,name=vdagent"});
            add({"-device", "virtserialport,bus=vser0.0,chardev=vdagent0,name=com.redhat.spice.0"});
        }
        if (!c.control_socket.empty()) {
            add({"-chardev", "socket,id=ctl0,path=" + qopt(c.control_socket) + ",server=on,wait=off"});
            add({"-device", "virtserialport,bus=vser0.0,chardev=ctl0,name=org.ideck.control"});
        }
        if (!c.input_socket.empty()) {
            add({"-chardev", "socket,id=inp0,path=" + qopt(c.input_socket) + ",server=on,wait=off"});
            add({"-device", "virtserialport,bus=vser0.0,chardev=inp0,name=org.ideck.input"});
        }
    }

    if (!c.qmp_socket.empty()) {
        add({"-chardev", "socket,id=qmp0,path=" + qopt(c.qmp_socket) + ",server=on,wait=off"});
        add({"-mon", "chardev=qmp0,mode=control"});
    }

    if (c.balloon) {
        // Free page reporting hands pages the guest frees back to the host.
        add({"-device", "virtio-balloon-pci,id=balloon0,free-page-reporting=on,deflate-on-oom=on"});
    }

    if (!c.console_log.empty()) {
        add({"-chardev", "file,id=con0,path=" + qopt(c.console_log)});
        add({"-serial", "chardev:con0"});
    } else {
        add({"-serial", "null"});
    }

    r.ok = true;
    return r;
}

bool vm_config_from_json(const Json& j, VmConfig& c, std::string* err) {
    if (!j.is_object()) {
        if (err) *err = "vm config must be an object";
        return false;
    }
    std::string profile = j["profile"].string_or("ios");
    if (profile == "ios") c.profile = QemuProfile::IOS;
    else if (profile == "desktop-test") c.profile = QemuProfile::DesktopTest;
    else {
        if (err) *err = "unknown profile '" + profile + "'";
        return false;
    }
    c.kernel = j["kernel"].string_or(c.kernel);
    c.initrd = j["initrd"].string_or(c.initrd);
    c.system_disk = j["system_disk"].string_or(c.system_disk);
    c.data_disk = j["data_disk"].string_or(c.data_disk);
    c.extra_disks.clear();
    for (const auto& d : j["extra_disks"].items()) c.extra_disks.push_back(d.as_string());
    c.cmdline = j["cmdline"].string_or(c.cmdline);
    c.guest_mb = static_cast<uint64_t>(j["guest_mb"].as_int(static_cast<int64_t>(c.guest_mb)));
    c.cpus = static_cast<int>(j["cpus"].as_int(c.cpus));
    c.tb_cache_mb = static_cast<uint64_t>(j["tb_cache_mb"].as_int(static_cast<int64_t>(c.tb_cache_mb)));
    c.cpu_model = j["cpu_model"].string_or(c.cpu_model);
    c.multithread_tcg = j["multithread_tcg"].as_bool(c.multithread_tcg);
    c.split_wx = j["split_wx"].as_bool(c.split_wx);
    c.ram_file = j["ram_file"].string_or(c.ram_file);
    c.gl = j["gl"].as_bool(c.gl);
    c.vulkan = j["vulkan"].as_bool(c.vulkan);
    c.hostmem_mb = static_cast<uint64_t>(j["hostmem_mb"].as_int(static_cast<int64_t>(c.hostmem_mb)));
    c.width = static_cast<int>(j["width"].as_int(c.width));
    c.height = static_cast<int>(j["height"].as_int(c.height));
    c.refresh_hz = static_cast<int>(j["refresh_hz"].as_int(c.refresh_hz));
    c.spice_socket = j["spice_socket"].string_or(c.spice_socket);
    c.qmp_socket = j["qmp_socket"].string_or(c.qmp_socket);
    c.control_socket = j["control_socket"].string_or(c.control_socket);
    c.input_socket = j["input_socket"].string_or(c.input_socket);
    c.console_log = j["console_log"].string_or(c.console_log);
    c.audio = j["audio"].string_or(c.audio);
    c.balloon = j["balloon"].as_bool(c.balloon);
    c.mac = j["mac"].string_or(c.mac);
    c.usb_input = j["usb_input"].as_bool(c.usb_input);
    return true;
}

Json vm_config_to_json(const VmConfig& c) {
    Json j = Json::object();
    j.set("profile", c.profile == QemuProfile::IOS ? "ios" : "desktop-test");
    j.set("kernel", c.kernel);
    j.set("initrd", c.initrd);
    j.set("system_disk", c.system_disk);
    j.set("data_disk", c.data_disk);
    Json ex = Json::array();
    for (const auto& d : c.extra_disks) ex.push(d);
    j.set("extra_disks", std::move(ex));
    j.set("cmdline", c.cmdline);
    j.set("guest_mb", c.guest_mb);
    j.set("cpus", c.cpus);
    j.set("tb_cache_mb", c.tb_cache_mb);
    j.set("cpu_model", c.cpu_model);
    j.set("multithread_tcg", c.multithread_tcg);
    j.set("split_wx", c.split_wx);
    j.set("ram_file", c.ram_file);
    j.set("gl", c.gl);
    j.set("vulkan", c.vulkan);
    j.set("hostmem_mb", c.hostmem_mb);
    j.set("width", c.width);
    j.set("height", c.height);
    j.set("refresh_hz", c.refresh_hz);
    j.set("spice_socket", c.spice_socket);
    j.set("qmp_socket", c.qmp_socket);
    j.set("control_socket", c.control_socket);
    j.set("input_socket", c.input_socket);
    j.set("console_log", c.console_log);
    j.set("audio", c.audio);
    j.set("balloon", c.balloon);
    j.set("mac", c.mac);
    j.set("usb_input", c.usb_input);
    return j;
}

}  // namespace ideck
