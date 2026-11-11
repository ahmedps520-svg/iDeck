// iDeck core — host <-> guest protocols. Shared by the iOS app, the desktop
// test host and the guest agent, so both ends are built from one definition.
//
// Control channel (virtio-serial port "org.ideck.control"):
//   newline-delimited JSON, one object per line.
//   request : {"id":N,"op":"status","args":{...}}
//   response: {"id":N,"ok":true,"result":{...}} | {"id":N,"ok":false,"error":"..."}
//   event   : {"event":"ready","data":{...}}  (guest -> host, unsolicited)
//
// Input channel (virtio-serial port "org.ideck.input"):
//   fixed 32-byte little-endian packets (see InputPacket).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "ideck/json.hpp"

namespace ideck {

constexpr const char* kControlPortName = "org.ideck.control";
constexpr const char* kInputPortName = "org.ideck.input";
constexpr int kProtocolVersion = 1;

// Splits a byte stream into lines. Lines longer than `max_line` are dropped
// (and counted) so a misbehaving peer cannot exhaust memory.
class LineFramer {
public:
    explicit LineFramer(size_t max_line = 1 << 20) : max_line_(max_line) {}
    // Appends bytes; returns the complete lines found (without '\n' / '\r').
    std::vector<std::string> feed(std::string_view bytes);
    size_t dropped() const { return dropped_; }
    size_t buffered() const { return buf_.size(); }

private:
    std::string buf_;
    size_t max_line_;
    size_t dropped_ = 0;
    bool discarding_ = false;
};

struct ControlMessage {
    enum class Kind { Request, Response, Event, Invalid } kind = Kind::Invalid;
    int64_t id = 0;
    std::string op;       // request
    Json args;            // request
    bool ok = false;      // response
    Json result;          // response
    std::string error;    // response / invalid
    std::string event;    // event
    Json data;            // event
};

ControlMessage parse_control_line(std::string_view line);
std::string make_request(int64_t id, std::string_view op, const Json& args);
std::string make_response(int64_t id, const Json& result);
std::string make_error(int64_t id, std::string_view error);
std::string make_event(std::string_view event, const Json& data);

// ---- Input packets -------------------------------------------------------

enum class InputType : uint8_t {
    PadState = 1,       // host -> guest
    PadConnect = 2,     // host -> guest
    PadDisconnect = 3,  // host -> guest
    Rumble = 4,         // guest -> host
    Keepalive = 5,
};

enum class PadKind : uint8_t { Generic = 0, Xbox = 1, PlayStation = 2, Nintendo = 3 };

// Button bits (Xbox layout; PlayStation maps Cross=A, Circle=B, Square=X,
// Triangle=Y). Positional, matching what SDL/Steam expect from an XInput pad.
enum PadButton : uint32_t {
    kBtnA = 1u << 0,
    kBtnB = 1u << 1,
    kBtnX = 1u << 2,
    kBtnY = 1u << 3,
    kBtnLB = 1u << 4,
    kBtnRB = 1u << 5,
    kBtnBack = 1u << 6,
    kBtnStart = 1u << 7,
    kBtnGuide = 1u << 8,
    kBtnLS = 1u << 9,
    kBtnRS = 1u << 10,
    kBtnDpadUp = 1u << 11,
    kBtnDpadDown = 1u << 12,
    kBtnDpadLeft = 1u << 13,
    kBtnDpadRight = 1u << 14,
    kBtnShare = 1u << 15,
};

struct InputPacket {
    InputType type = InputType::Keepalive;
    uint8_t pad = 0;         // 0..3
    PadKind kind = PadKind::Generic;
    uint16_t seq = 0;
    uint32_t buttons = 0;
    int16_t lx = 0, ly = 0, rx = 0, ry = 0;  // +y is up (host convention)
    uint16_t lt = 0, rt = 0;                 // 0..65535
    uint16_t rumble_strong = 0, rumble_weak = 0;
    uint16_t rumble_ms = 0;
};

constexpr size_t kInputPacketSize = 32;
constexpr uint8_t kInputMagic0 = 'I';
constexpr uint8_t kInputMagic1 = 'D';

void encode_input(const InputPacket& p, uint8_t out[kInputPacketSize]);
bool decode_input(const uint8_t in[kInputPacketSize], InputPacket& out);

// Re-synchronising decoder for a byte stream of packets.
class InputStreamDecoder {
public:
    std::vector<InputPacket> feed(const uint8_t* data, size_t len);
    size_t resyncs() const { return resyncs_; }

private:
    std::vector<uint8_t> buf_;
    size_t resyncs_ = 0;
};

// Maps a float axis in [-1, 1] / trigger in [0, 1] to packet units.
int16_t axis_to_i16(float v);
uint16_t trigger_to_u16(float v);

}  // namespace ideck
