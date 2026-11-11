#include "gamepad.hpp"

#include <cstdio>
#include <cstring>

#if defined(__linux__)
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>
#include <unistd.h>
#endif

namespace agent {

using ideck::InputPacket;
using ideck::InputType;

#if defined(__linux__)
namespace {

struct ButtonMap {
    uint32_t bit;
    uint16_t code;
};

const ButtonMap kButtons[] = {
    {ideck::kBtnA, BTN_SOUTH},     {ideck::kBtnB, BTN_EAST},      {ideck::kBtnX, BTN_NORTH},
    {ideck::kBtnY, BTN_WEST},      {ideck::kBtnLB, BTN_TL},       {ideck::kBtnRB, BTN_TR},
    {ideck::kBtnBack, BTN_SELECT}, {ideck::kBtnStart, BTN_START}, {ideck::kBtnGuide, BTN_MODE},
    {ideck::kBtnLS, BTN_THUMBL},   {ideck::kBtnRS, BTN_THUMBR},
};

int hat(uint32_t buttons, uint32_t neg, uint32_t pos) {
    int v = 0;
    if (buttons & neg) v -= 1;
    if (buttons & pos) v += 1;
    return v;
}

int16_t flip(int16_t v) { return v == -32768 ? 32767 : static_cast<int16_t>(-v); }

bool emit(int fd, uint16_t type, uint16_t code, int32_t value) {
    input_event ev;
    std::memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    return write(fd, &ev, sizeof(ev)) == static_cast<ssize_t>(sizeof(ev));
}

}  // namespace

std::vector<LinuxPadEvent> pad_events(const InputPacket& a, const InputPacket& b) {
    std::vector<LinuxPadEvent> out;
    for (const auto& m : kButtons) {
        bool was = (a.buttons & m.bit) != 0;
        bool is = (b.buttons & m.bit) != 0;
        if (was != is) out.push_back({EV_KEY, m.code, is ? 1 : 0});
    }
    auto axis = [&](uint16_t code, int32_t va, int32_t vb) {
        if (va != vb) out.push_back({EV_ABS, code, vb});
    };
    // Host +y is up; evdev +y is down.
    axis(ABS_X, a.lx, b.lx);
    axis(ABS_Y, flip(a.ly), flip(b.ly));
    axis(ABS_RX, a.rx, b.rx);
    axis(ABS_RY, flip(a.ry), flip(b.ry));
    axis(ABS_Z, a.lt >> 8, b.lt >> 8);
    axis(ABS_RZ, a.rt >> 8, b.rt >> 8);
    axis(ABS_HAT0X, hat(a.buttons, ideck::kBtnDpadLeft, ideck::kBtnDpadRight),
         hat(b.buttons, ideck::kBtnDpadLeft, ideck::kBtnDpadRight));
    axis(ABS_HAT0Y, hat(a.buttons, ideck::kBtnDpadUp, ideck::kBtnDpadDown),
         hat(b.buttons, ideck::kBtnDpadUp, ideck::kBtnDpadDown));
    return out;
}

GamepadHub::~GamepadHub() { disconnect_all(); }

bool GamepadHub::create(int index, ideck::PadKind kind) {
    (void)kind;  // all pads present as XInput; see header comment
    int fd = open("/dev/uinput", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        std::perror("ideck-agent: open /dev/uinput");
        return false;
    }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (const auto& m : kButtons) ioctl(fd, UI_SET_KEYBIT, m.code);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_EVBIT, EV_FF);
    ioctl(fd, UI_SET_FFBIT, FF_RUMBLE);

    struct AbsSpec {
        uint16_t code;
        int32_t min, max, fuzz, flat;
    };
    const AbsSpec axes[] = {
        {ABS_X, -32768, 32767, 16, 128},  {ABS_Y, -32768, 32767, 16, 128},  {ABS_RX, -32768, 32767, 16, 128},
        {ABS_RY, -32768, 32767, 16, 128}, {ABS_Z, 0, 255, 0, 0},            {ABS_RZ, 0, 255, 0, 0},
        {ABS_HAT0X, -1, 1, 0, 0},         {ABS_HAT0Y, -1, 1, 0, 0},
    };
    for (const auto& a : axes) {
        ioctl(fd, UI_SET_ABSBIT, a.code);
        uinput_abs_setup s;
        std::memset(&s, 0, sizeof(s));
        s.code = a.code;
        s.absinfo.minimum = a.min;
        s.absinfo.maximum = a.max;
        s.absinfo.fuzz = a.fuzz;
        s.absinfo.flat = a.flat;
        ioctl(fd, UI_ABS_SETUP, &s);
    }
    uinput_setup setup;
    std::memset(&setup, 0, sizeof(setup));
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x045e;
    setup.id.product = 0x028e;
    setup.id.version = 0x0110;
    setup.ff_effects_max = 16;
    std::snprintf(setup.name, sizeof(setup.name), "Microsoft X-Box 360 pad (iDeck %d)", index + 1);
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        std::perror("ideck-agent: create uinput pad");
        close(fd);
        return false;
    }
    pads_[index].fd = fd;
    pads_[index].state = InputPacket();
    pads_[index].effects.clear();
    return true;
}

void GamepadHub::destroy(int index) {
    Pad& p = pads_[index];
    if (p.fd >= 0) {
        ioctl(p.fd, UI_DEV_DESTROY);
        close(p.fd);
    }
    p.fd = -1;
    p.effects.clear();
    p.state = InputPacket();
}

void GamepadHub::disconnect_all() {
    for (int i = 0; i < 4; ++i) destroy(i);
}

void GamepadHub::handle(const InputPacket& pkt) {
    if (pkt.pad > 3) return;
    Pad& p = pads_[pkt.pad];
    switch (pkt.type) {
        case InputType::PadConnect:
            if (p.fd < 0) create(pkt.pad, pkt.kind);
            break;
        case InputType::PadDisconnect:
            destroy(pkt.pad);
            break;
        case InputType::PadState: {
            if (p.fd < 0 && !create(pkt.pad, pkt.kind)) return;
            auto evs = pad_events(p.state, pkt);
            if (evs.empty()) break;
            for (const auto& e : evs) emit(p.fd, e.type, e.code, e.value);
            emit(p.fd, EV_SYN, SYN_REPORT, 0);
            p.state = pkt;
            break;
        }
        default:
            break;
    }
}

std::vector<int> GamepadHub::fds() const {
    std::vector<int> out;
    for (const auto& p : pads_) {
        if (p.fd >= 0) out.push_back(p.fd);
    }
    return out;
}

void GamepadHub::service(int fd) {
    int index = -1;
    for (int i = 0; i < 4; ++i) {
        if (pads_[i].fd == fd) index = i;
    }
    if (index < 0) return;
    Pad& p = pads_[index];
    input_event ev;
    while (read(fd, &ev, sizeof(ev)) == static_cast<ssize_t>(sizeof(ev))) {
        if (ev.type == EV_UINPUT && ev.code == UI_FF_UPLOAD) {
            uinput_ff_upload up;
            std::memset(&up, 0, sizeof(up));
            up.request_id = static_cast<uint32_t>(ev.value);
            if (ioctl(fd, UI_BEGIN_FF_UPLOAD, &up) < 0) continue;
            Pad::Effect e;
            e.id = up.effect.id;
            if (up.effect.type == FF_RUMBLE) {
                e.strong = up.effect.u.rumble.strong_magnitude;
                e.weak = up.effect.u.rumble.weak_magnitude;
            }
            e.length_ms = up.effect.replay.length;
            bool replaced = false;
            for (auto& x : p.effects) {
                if (x.id == e.id) {
                    x = e;
                    replaced = true;
                }
            }
            if (!replaced) p.effects.push_back(e);
            up.retval = up.effect.type == FF_RUMBLE ? 0 : -EINVAL;
            ioctl(fd, UI_END_FF_UPLOAD, &up);
        } else if (ev.type == EV_UINPUT && ev.code == UI_FF_ERASE) {
            uinput_ff_erase er;
            std::memset(&er, 0, sizeof(er));
            er.request_id = static_cast<uint32_t>(ev.value);
            if (ioctl(fd, UI_BEGIN_FF_ERASE, &er) < 0) continue;
            for (size_t i = 0; i < p.effects.size(); ++i) {
                if (p.effects[i].id == static_cast<int16_t>(er.effect_id)) {
                    p.effects.erase(p.effects.begin() + static_cast<std::ptrdiff_t>(i));
                    break;
                }
            }
            er.retval = 0;
            ioctl(fd, UI_END_FF_ERASE, &er);
        } else if (ev.type == EV_FF && ev.code != FF_GAIN) {
            InputPacket r;
            r.type = InputType::Rumble;
            r.pad = static_cast<uint8_t>(index);
            for (const auto& x : p.effects) {
                if (x.id == static_cast<int16_t>(ev.code) && ev.value > 0) {
                    r.rumble_strong = x.strong;
                    r.rumble_weak = x.weak;
                    r.rumble_ms = x.length_ms ? x.length_ms : 1000;
                }
            }
            // value == 0 (stop) sends a zero-magnitude rumble.
            if (sink_) sink_(r);
        }
    }
}

#else  // non-Linux builds (host unit tests): no uinput

std::vector<LinuxPadEvent> pad_events(const InputPacket&, const InputPacket&) { return {}; }
GamepadHub::~GamepadHub() {}
bool GamepadHub::create(int, ideck::PadKind) { return false; }
void GamepadHub::destroy(int) {}
void GamepadHub::disconnect_all() {}
void GamepadHub::handle(const InputPacket&) {}
std::vector<int> GamepadHub::fds() const { return {}; }
void GamepadHub::service(int) {}

#endif

}  // namespace agent
