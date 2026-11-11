#include "ideck/protocol.hpp"

#include <cmath>
#include <cstring>

namespace ideck {

std::vector<std::string> LineFramer::feed(std::string_view bytes) {
    std::vector<std::string> lines;
    size_t start = 0;
    while (start < bytes.size()) {
        size_t nl = bytes.find('\n', start);
        std::string_view chunk = bytes.substr(start, nl == std::string_view::npos ? std::string_view::npos : nl - start);
        if (!discarding_) {
            if (buf_.size() + chunk.size() > max_line_) {
                // Too long: drop everything until the next newline.
                buf_.clear();
                discarding_ = true;
                ++dropped_;
            } else {
                buf_.append(chunk.data(), chunk.size());
            }
        }
        if (nl == std::string_view::npos) break;
        if (!discarding_) {
            if (!buf_.empty() && buf_.back() == '\r') buf_.pop_back();
            if (!buf_.empty()) lines.push_back(std::move(buf_));
        }
        buf_.clear();
        discarding_ = false;
        start = nl + 1;
    }
    return lines;
}

ControlMessage parse_control_line(std::string_view line) {
    ControlMessage m;
    Json j;
    std::string err;
    if (!Json::parse(line, j, &err)) {
        m.error = "invalid JSON: " + err;
        return m;
    }
    if (!j.is_object()) {
        m.error = "message must be an object";
        return m;
    }
    if (j.contains("event")) {
        m.kind = ControlMessage::Kind::Event;
        m.event = j["event"].as_string();
        m.data = j["data"];
        if (m.event.empty()) {
            m.kind = ControlMessage::Kind::Invalid;
            m.error = "event name must be a non-empty string";
        }
        return m;
    }
    if (!j["id"].is_number()) {
        m.error = "message needs a numeric id";
        return m;
    }
    m.id = j["id"].as_int();
    if (j.contains("op")) {
        m.kind = ControlMessage::Kind::Request;
        m.op = j["op"].as_string();
        m.args = j["args"].is_null() ? Json::object() : j["args"];
        if (m.op.empty()) {
            m.kind = ControlMessage::Kind::Invalid;
            m.error = "op must be a non-empty string";
        }
        return m;
    }
    if (j.contains("ok")) {
        m.kind = ControlMessage::Kind::Response;
        m.ok = j["ok"].as_bool(false);
        m.result = j["result"];
        m.error = j["error"].as_string();
        return m;
    }
    m.error = "message is neither request, response nor event";
    return m;
}

std::string make_request(int64_t id, std::string_view op, const Json& args) {
    Json j = Json::object();
    j.set("id", static_cast<long long>(id));
    j.set("op", std::string(op));
    j.set("args", args.is_null() ? Json::object() : args);
    return j.dump() + "\n";
}

std::string make_response(int64_t id, const Json& result) {
    Json j = Json::object();
    j.set("id", static_cast<long long>(id));
    j.set("ok", true);
    j.set("result", result);
    return j.dump() + "\n";
}

std::string make_error(int64_t id, std::string_view error) {
    Json j = Json::object();
    j.set("id", static_cast<long long>(id));
    j.set("ok", false);
    j.set("error", std::string(error));
    return j.dump() + "\n";
}

std::string make_event(std::string_view event, const Json& data) {
    Json j = Json::object();
    j.set("event", std::string(event));
    j.set("data", data);
    return j.dump() + "\n";
}

namespace {

void put16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
}
void put32(uint8_t* p, uint32_t v) {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}
uint16_t get16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
uint32_t get32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

// Layout (little-endian):
//  0 magic 'I' 'D'   2 version   3 type   4 pad   5 kind   6 seq(u16)
//  8 buttons(u32)   12 lx 14 ly 16 rx 18 ry (i16)   20 lt 22 rt (u16)
// 24 rumble_strong 26 rumble_weak 28 rumble_ms (u16)   30 checksum(u16)
uint16_t checksum(const uint8_t* p) {
    // Fletcher-16 over bytes 0..29: cheap and catches framing slips.
    uint16_t a = 0, b = 0;
    for (int i = 0; i < 30; ++i) {
        a = static_cast<uint16_t>((a + p[i]) % 255);
        b = static_cast<uint16_t>((b + a) % 255);
    }
    return static_cast<uint16_t>((b << 8) | a);
}

}  // namespace

void encode_input(const InputPacket& p, uint8_t out[kInputPacketSize]) {
    std::memset(out, 0, kInputPacketSize);
    out[0] = kInputMagic0;
    out[1] = kInputMagic1;
    out[2] = static_cast<uint8_t>(kProtocolVersion);
    out[3] = static_cast<uint8_t>(p.type);
    out[4] = p.pad;
    out[5] = static_cast<uint8_t>(p.kind);
    put16(out + 6, p.seq);
    put32(out + 8, p.buttons);
    put16(out + 12, static_cast<uint16_t>(p.lx));
    put16(out + 14, static_cast<uint16_t>(p.ly));
    put16(out + 16, static_cast<uint16_t>(p.rx));
    put16(out + 18, static_cast<uint16_t>(p.ry));
    put16(out + 20, p.lt);
    put16(out + 22, p.rt);
    put16(out + 24, p.rumble_strong);
    put16(out + 26, p.rumble_weak);
    put16(out + 28, p.rumble_ms);
    put16(out + 30, checksum(out));
}

bool decode_input(const uint8_t in[kInputPacketSize], InputPacket& p) {
    if (in[0] != kInputMagic0 || in[1] != kInputMagic1) return false;
    if (in[2] != kProtocolVersion) return false;
    if (get16(in + 30) != checksum(in)) return false;
    uint8_t type = in[3];
    if (type < 1 || type > 5) return false;
    if (in[4] > 3) return false;
    p.type = static_cast<InputType>(type);
    p.pad = in[4];
    p.kind = static_cast<PadKind>(in[5] <= 3 ? in[5] : 0);
    p.seq = get16(in + 6);
    p.buttons = get32(in + 8);
    p.lx = static_cast<int16_t>(get16(in + 12));
    p.ly = static_cast<int16_t>(get16(in + 14));
    p.rx = static_cast<int16_t>(get16(in + 16));
    p.ry = static_cast<int16_t>(get16(in + 18));
    p.lt = get16(in + 20);
    p.rt = get16(in + 22);
    p.rumble_strong = get16(in + 24);
    p.rumble_weak = get16(in + 26);
    p.rumble_ms = get16(in + 28);
    return true;
}

std::vector<InputPacket> InputStreamDecoder::feed(const uint8_t* data, size_t len) {
    std::vector<InputPacket> out;
    buf_.insert(buf_.end(), data, data + len);
    size_t pos = 0;
    while (buf_.size() - pos >= kInputPacketSize) {
        InputPacket p;
        if (decode_input(buf_.data() + pos, p)) {
            out.push_back(p);
            pos += kInputPacketSize;
        } else {
            // Slide one byte and look for the next magic.
            ++pos;
            ++resyncs_;
            while (pos < buf_.size() && buf_[pos] != kInputMagic0) ++pos;
        }
    }
    buf_.erase(buf_.begin(), buf_.begin() + static_cast<std::ptrdiff_t>(pos));
    return out;
}

int16_t axis_to_i16(float v) {
    if (!(v == v)) return 0;  // NaN
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    long r = std::lround(static_cast<double>(v) * 32767.0);
    return static_cast<int16_t>(r);
}

uint16_t trigger_to_u16(float v) {
    if (!(v == v)) return 0;
    if (v > 1.0f) v = 1.0f;
    if (v < 0.0f) v = 0.0f;
    return static_cast<uint16_t>(std::lround(static_cast<double>(v) * 65535.0));
}

}  // namespace ideck
