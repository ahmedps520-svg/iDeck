// Tests: QEMU argv builder, guest protocols, QMP session, C API.
#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "ideck/protocol.hpp"
#include "ideck/qemu_args.hpp"
#include "ideck/qmp.hpp"
#include "ideck_core.h"
#include "testing.hpp"

using namespace ideck;

namespace {

bool has_pair(const std::vector<std::string>& argv, const std::string& flag, const std::string& value_part) {
    for (size_t i = 0; i + 1 < argv.size(); ++i) {
        if (argv[i] == flag && argv[i + 1].find(value_part) != std::string::npos) return true;
    }
    return false;
}

VmConfig ios_config() {
    VmConfig c;
    c.kernel = "/rt/Image";
    c.initrd = "/rt/initrd.img";
    c.system_disk = "/rt/system.img";
    c.data_disk = "/data/data.img";
    c.spice_socket = "/tmp/s.sock";
    c.qmp_socket = "/tmp/q.sock";
    c.control_socket = "/tmp/c.sock";
    c.input_socket = "/tmp/i.sock";
    c.guest_mb = 3072;
    c.tb_cache_mb = 384;
    return c;
}

Json call(const char* method, const std::string& args) {
    char* out = ideck_call(method, args.c_str());
    Json j;
    Json::parse(out, j);
    ideck_free(out);
    return j;
}

}  // namespace

TEST("qemu: iOS profile builds the expected device set") {
    QemuArgsResult r = build_qemu_args(ios_config());
    CHECK(r.ok);
    const auto& a = r.argv;
    CHECK_EQ(a.front(), std::string("qemu-system-aarch64"));
    CHECK(has_pair(a, "-accel", "tcg,thread=multi,tb-size=384,split-wx=on"));
    CHECK(has_pair(a, "-cpu", "neoverse-n1"));
    CHECK(has_pair(a, "-m", "3072M"));
    CHECK(has_pair(a, "-machine", "virt,gic-version=3"));
    CHECK(has_pair(a, "-device", "virtio-gpu-gl-pci"));
    CHECK(has_pair(a, "-device", "blob=true,venus=true,hostmem=2048M"));
    CHECK(has_pair(a, "-spice", "unix=on,addr=/tmp/s.sock"));
    CHECK(has_pair(a, "-spice", "gl=on"));
    CHECK(has_pair(a, "-device", "name=org.ideck.control"));
    CHECK(has_pair(a, "-device", "name=org.ideck.input"));
    CHECK(has_pair(a, "-mon", "chardev=qmp0,mode=control"));
    CHECK(has_pair(a, "-device", "virtio-balloon-pci"));
    CHECK(has_pair(a, "-drive", "file=/data/data.img"));
    // Discard fails on device for every request; not offered on iOS.
    CHECK(has_pair(a, "-drive", "discard=ignore"));
    CHECK(!has_pair(a, "-drive", "discard=unmap"));
    CHECK(has_pair(a, "-audiodev", "spice"));
    // No capture device for the guest (it made SPICE record from the mic).
    CHECK(has_pair(a, "-device", "hda-output"));
    CHECK(!has_pair(a, "-device", "hda-duplex"));
    CHECK(has_pair(a, "-device", "name=com.redhat.spice.0"));
    // Regression (first device run): utmapp/qemu 10.0.12 rejects this
    // property on virtio-gpu-gl-pci and QEMU exits immediately.
    CHECK(!has_pair(a, "-device", "refresh_rate"));
    CHECK(!has_pair(a, "-display", "none"));
}

TEST("qemu: desktop-test profile is headless and stock-QEMU compatible") {
    VmConfig c = ios_config();
    c.profile = QemuProfile::DesktopTest;
    c.spice_socket.clear();
    QemuArgsResult r = build_qemu_args(c);
    CHECK(r.ok);
    CHECK(has_pair(r.argv, "-display", "none"));
    CHECK(has_pair(r.argv, "-device", "virtio-gpu-pci"));
    CHECK(!has_pair(r.argv, "-accel", "split-wx"));
    CHECK(std::find(r.argv.begin(), r.argv.end(), "-spice") == r.argv.end());
}

TEST("qemu: validation errors") {
    VmConfig c = ios_config();
    c.qmp_socket = "/" + std::string(200, 'x');
    CHECK(!build_qemu_args(c).ok);
    c = ios_config();
    c.cpu_model = "pentium";
    CHECK(!build_qemu_args(c).ok);
    c = ios_config();
    c.spice_socket.clear();
    CHECK(!build_qemu_args(c).ok);
    c = ios_config();
    c.cpu_model = "cortex-a72";
    QemuArgsResult w = build_qemu_args(c);
    CHECK(w.ok);
    CHECK(!w.warnings.empty());
}

TEST("qemu: file-backed RAM and comma escaping") {
    VmConfig c = ios_config();
    c.ram_file = "/data/ram,1.bin";
    c.cpu_model = "max";
    QemuArgsResult r = build_qemu_args(c);
    CHECK(r.ok);
    CHECK(has_pair(r.argv, "-machine", "memory-backend=ram0"));
    CHECK(has_pair(r.argv, "-object", "mem-path=/data/ram,,1.bin"));
    CHECK(has_pair(r.argv, "-cpu", "max,pauth=off,sve=off,sme=off"));
}

TEST("qemu: config JSON round trip") {
    VmConfig c = ios_config();
    c.width = 1920;
    c.height = 1080;
    VmConfig back;
    CHECK(vm_config_from_json(vm_config_to_json(c), back));
    CHECK_EQ(back.width, 1920);
    CHECK_EQ(back.spice_socket, c.spice_socket);
    CHECK(build_qemu_args(back).argv == build_qemu_args(c).argv);
}

TEST("protocol: line framer handles splits, CRLF and overlong lines") {
    LineFramer f(16);
    auto l1 = f.feed("hel");
    CHECK(l1.empty());
    auto l2 = f.feed("lo\r\nwor");
    CHECK_EQ(l2.size(), 1u);
    CHECK_EQ(l2[0], std::string("hello"));
    auto l3 = f.feed("ld\n\n");
    CHECK_EQ(l3.size(), 1u);
    CHECK_EQ(l3[0], std::string("world"));
    auto l4 = f.feed(std::string(40, 'x') + "\nok\n");
    CHECK_EQ(l4.size(), 1u);
    CHECK_EQ(l4[0], std::string("ok"));
    CHECK_EQ(f.dropped(), 1u);
}

TEST("protocol: control messages") {
    ControlMessage req = parse_control_line(make_request(7, "status", Json::object()));
    CHECK(req.kind == ControlMessage::Kind::Request);
    CHECK_EQ(req.id, 7);
    CHECK_EQ(req.op, std::string("status"));
    Json res = Json::object();
    res.set("mem", 1);
    ControlMessage ok = parse_control_line(make_response(7, res));
    CHECK(ok.kind == ControlMessage::Kind::Response);
    CHECK(ok.ok);
    CHECK_EQ(ok.result["mem"].as_int(), 1);
    ControlMessage err = parse_control_line(make_error(8, "nope"));
    CHECK(!err.ok);
    CHECK_EQ(err.error, std::string("nope"));
    ControlMessage ev = parse_control_line(make_event("ready", Json::object()));
    CHECK(ev.kind == ControlMessage::Kind::Event);
    CHECK_EQ(ev.event, std::string("ready"));
    CHECK(parse_control_line("garbage").kind == ControlMessage::Kind::Invalid);
    CHECK(parse_control_line("{\"op\":\"x\"}").kind == ControlMessage::Kind::Invalid);
}

TEST("protocol: input packets round trip and resync") {
    InputPacket p;
    p.type = InputType::PadState;
    p.pad = 2;
    p.kind = PadKind::PlayStation;
    p.seq = 513;
    p.buttons = kBtnA | kBtnStart | kBtnDpadLeft;
    p.lx = -32767;
    p.ly = 12345;
    p.rx = 1;
    p.ry = -1;
    p.lt = 65535;
    p.rt = 7;
    uint8_t buf[kInputPacketSize];
    encode_input(p, buf);
    InputPacket q;
    CHECK(decode_input(buf, q));
    CHECK(q.type == InputType::PadState);
    CHECK_EQ(q.pad, 2);
    CHECK(q.kind == PadKind::PlayStation);
    CHECK_EQ(q.seq, 513);
    CHECK_EQ(q.buttons, p.buttons);
    CHECK_EQ(q.lx, -32767);
    CHECK_EQ(q.ly, 12345);
    CHECK_EQ(q.lt, 65535);
    CHECK_EQ(q.rt, 7);

    uint8_t corrupt[kInputPacketSize];
    std::memcpy(corrupt, buf, sizeof(buf));
    corrupt[10] ^= 0x40;
    CHECK(!decode_input(corrupt, q));

    // Stream: junk byte, packet, packet split across feeds.
    std::vector<uint8_t> stream;
    stream.push_back(0x55);
    stream.insert(stream.end(), buf, buf + kInputPacketSize);
    stream.insert(stream.end(), buf, buf + kInputPacketSize);
    InputStreamDecoder d;
    auto a = d.feed(stream.data(), 20);
    auto b = d.feed(stream.data() + 20, stream.size() - 20);
    CHECK_EQ(a.size() + b.size(), 2u);
    CHECK(d.resyncs() >= 1);

    CHECK_EQ(axis_to_i16(1.5f), 32767);
    CHECK_EQ(axis_to_i16(-1.0f), -32767);
    CHECK_EQ(axis_to_i16(0.0f), 0);
    CHECK_EQ(trigger_to_u16(1.0f), 65535);
    CHECK_EQ(trigger_to_u16(-3.0f), 0);
}

TEST("qmp: negotiation, queued commands, replies and events") {
    QmpSession s;
    std::string out;
    std::string cmd_wire;
    int64_t early = s.command("query-status", Json(), cmd_wire);
    CHECK(cmd_wire.empty());  // queued until negotiated
    auto r0 = s.feed("{\"QMP\": {\"version\": {\"qemu\": {\"major\": 10}}, \"capabilities\": []}}\r\n", out);
    CHECK(r0.empty());
    CHECK(s.state() == QmpSession::State::Negotiating);
    CHECK(out.find("qmp_capabilities") != std::string::npos);
    CHECK(out.find("\"id\":0") != std::string::npos);
    out.clear();
    s.feed("{\"return\": {}, \"id\": 0}\r\n", out);
    CHECK(s.state() == QmpSession::State::Ready);
    CHECK(out.find("query-status") != std::string::npos);
    auto r1 = s.feed("{\"return\": {\"running\": true}, \"id\": " + std::to_string(early) +
                         "}\r\n{\"event\": \"RESET\", \"data\": {\"guest\": true}}\r\n",
                     out);
    CHECK_EQ(r1.size(), 2u);
    CHECK(r1[0].kind == QmpReply::Kind::Return);
    CHECK_EQ(r1[0].command, std::string("query-status"));
    CHECK(r1[0].value["running"].as_bool());
    CHECK(r1[1].kind == QmpReply::Kind::Event);
    CHECK_EQ(r1[1].event, std::string("RESET"));
    std::string w;
    int64_t id = s.command("block_resize", Json(), w);
    auto r2 = s.feed("{\"error\": {\"class\": \"GenericError\", \"desc\": \"bad\"}, \"id\": " +
                         std::to_string(id) + "}\n",
                     out);
    CHECK_EQ(r2.size(), 1u);
    CHECK(r2[0].kind == QmpReply::Kind::Error);
    CHECK_EQ(r2[0].error_desc, std::string("bad"));
}

TEST("c api: dispatch, errors and handles") {
    Json plan = call("memory.plan", R"({"physical_mb":12288,"app_limit_mb":6144,"increased_memory_limit":true})");
    CHECK(plan["ok"].as_bool());
    CHECK_EQ(plan["result"]["guest_mb"].as_int(), 3072);
    CHECK(!call("nope", "{}")["ok"].as_bool());
    CHECK(!call("memory.plan", "{bad")["ok"].as_bool());
    Json args = call("qemu.args", R"({"profile":"desktop-test","kernel":"/k","system_disk":"/s"})");
    CHECK(args["ok"].as_bool());
    CHECK(args["result"]["argv"].size() > 10);
    CHECK(!call("qemu.args", R"({"profile":"ios","kernel":"/k","system_disk":"/s"})")["ok"].as_bool());

    auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    auto dir = std::filesystem::temp_directory_path() / ("ideck-capi-" + std::to_string(stamp));
    std::filesystem::create_directories(dir);
    std::string jpath = (dir / "journal.json").string();
    Json pj = Json::object();
    pj.set("path", jpath);
    pj.set("id", "check-device");
    CHECK(call("journal.begin", pj.dump())["ok"].as_bool());
    CHECK(call("journal.complete", pj.dump())["ok"].as_bool());
    CHECK(!call("journal.complete", pj.dump())["ok"].as_bool());
    Json loaded = call("journal.load", pj.dump());
    CHECK_EQ(loaded["result"]["steps"].at(0)["state"].as_string(), std::string("done"));
    std::filesystem::remove_all(dir);

    ideck_sha256* h = ideck_sha256_new();
    ideck_sha256_update(h, "abc", 3);
    char hex[65];
    ideck_sha256_finish(h, hex);
    CHECK_EQ(std::string(hex), std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));

    ideck_framer* f = ideck_framer_new();
    char* lines = ideck_framer_feed(f, "a\nb", 3);
    CHECK_EQ(std::string(lines), std::string("[\"a\"]"));
    ideck_free(lines);
    ideck_framer_free(f);

    ideck_pad_state st{};
    st.type = 1;
    st.buttons = kBtnB;
    st.lx = 0.5f;
    uint8_t pkt[32];
    ideck_input_encode(&st, pkt);
    InputPacket q;
    CHECK(decode_input(pkt, q));
    CHECK_EQ(q.lx, 16384);

    InputPacket rum;
    rum.type = InputType::Rumble;
    rum.pad = 1;
    rum.rumble_strong = 40000;
    rum.rumble_ms = 120;
    uint8_t rbuf[32];
    encode_input(rum, rbuf);
    ideck_input_decoder* dec = ideck_input_decoder_new();
    ideck_rumble ev[4];
    CHECK_EQ(ideck_input_decoder_feed(dec, rbuf, 32, ev, 4), 1u);
    CHECK_EQ(ev[0].strong, 40000);
    CHECK_EQ(ev[0].duration_ms, 120);
    ideck_input_decoder_free(dec);
}
