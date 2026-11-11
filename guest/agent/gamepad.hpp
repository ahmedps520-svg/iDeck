// ideck-agent — virtual gamepads via /dev/uinput.
//
// Each host controller becomes a virtual Xbox 360 pad (045e:028e), the
// layout SDL and Steam Input recognise without extra mappings. Force
// feedback (FF_RUMBLE) uploaded by games is reported back to the host so
// the physical controller vibrates.
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include "ideck/protocol.hpp"

namespace agent {

struct LinuxPadEvent {
    uint16_t type;
    uint16_t code;
    int32_t value;
};

// Pure translation from a packet to the evdev events that change state.
// `prev` is the last applied state for this pad.
std::vector<LinuxPadEvent> pad_events(const ideck::InputPacket& prev, const ideck::InputPacket& next);

class GamepadHub {
public:
    using RumbleSink = std::function<void(const ideck::InputPacket&)>;

    explicit GamepadHub(RumbleSink sink) : sink_(std::move(sink)) {}
    ~GamepadHub();

    void handle(const ideck::InputPacket& p);
    // uinput fds that may have force-feedback requests to service.
    std::vector<int> fds() const;
    void service(int fd);
    void disconnect_all();

private:
    struct Pad {
        int fd = -1;
        ideck::InputPacket state;
        struct Effect {
            int16_t id = -1;
            uint16_t strong = 0;
            uint16_t weak = 0;
            uint16_t length_ms = 0;
        };
        std::vector<Effect> effects;
    };

    bool create(int index, ideck::PadKind kind);
    void destroy(int index);

    Pad pads_[4];
    RumbleSink sink_;
};

}  // namespace agent
