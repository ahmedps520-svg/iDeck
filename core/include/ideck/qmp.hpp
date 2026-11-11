// iDeck core — QEMU Machine Protocol session (transport-agnostic).
//
// Feed it bytes read from the QMP socket; it returns what to write back and
// the decoded replies/events. Used by the desktop test host and mirrored by
// the Swift QMP client in the app.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

#include "ideck/json.hpp"
#include "ideck/protocol.hpp"

namespace ideck {

struct QmpReply {
    enum class Kind { Return, Error, Event } kind = Kind::Event;
    int64_t id = 0;
    std::string command;  // command name for Return/Error
    Json value;           // "return" payload, or event "data"
    std::string error_class;
    std::string error_desc;
    std::string event;    // for events
};

class QmpSession {
public:
    enum class State { AwaitGreeting, Negotiating, Ready, Failed };

    // Processes incoming bytes. Bytes that must be written to the socket
    // (capability negotiation) are appended to `outgoing`.
    std::vector<QmpReply> feed(std::string_view bytes, std::string& outgoing);

    // Serialises a command; returns its id. Valid once state() == Ready
    // (earlier commands are queued and flushed after negotiation).
    int64_t command(std::string_view name, const Json& args, std::string& outgoing);

    State state() const { return state_; }
    const Json& greeting() const { return greeting_; }
    std::string error() const { return error_; }

private:
    void flush_queue(std::string& outgoing);

    State state_ = State::AwaitGreeting;
    LineFramer framer_;
    Json greeting_;
    std::string error_;
    int64_t next_id_ = 1;
    int64_t caps_id_ = 0;
    std::map<int64_t, std::string> pending_;
    std::vector<std::string> queued_;
};

}  // namespace ideck
