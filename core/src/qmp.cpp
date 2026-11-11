#include "ideck/qmp.hpp"

namespace ideck {

std::vector<QmpReply> QmpSession::feed(std::string_view bytes, std::string& outgoing) {
    std::vector<QmpReply> out;
    for (const auto& line : framer_.feed(bytes)) {
        Json j;
        std::string err;
        if (!Json::parse(line, j, &err) || !j.is_object()) continue;

        if (state_ == State::AwaitGreeting) {
            if (!j.contains("QMP")) continue;
            greeting_ = j["QMP"];
            // Id 0 is reserved for negotiation; commands start at 1, so a
            // command queued before the greeting can never collide with it.
            caps_id_ = 0;
            Json cmd = Json::object();
            cmd.set("execute", "qmp_capabilities");
            cmd.set("id", static_cast<long long>(caps_id_));
            outgoing += cmd.dump() + "\r\n";
            state_ = State::Negotiating;
            continue;
        }

        if (j.contains("event")) {
            QmpReply r;
            r.kind = QmpReply::Kind::Event;
            r.event = j["event"].as_string();
            r.value = j["data"];
            out.push_back(std::move(r));
            continue;
        }

        int64_t id = j["id"].as_int(0);
        if (state_ == State::Negotiating && id == caps_id_) {
            if (j.contains("return")) {
                state_ = State::Ready;
                flush_queue(outgoing);
            } else {
                state_ = State::Failed;
                error_ = j["error"]["desc"].as_string();
            }
            continue;
        }

        QmpReply r;
        r.id = id;
        auto it = pending_.find(id);
        if (it != pending_.end()) {
            r.command = it->second;
            pending_.erase(it);
        }
        if (j.contains("return")) {
            r.kind = QmpReply::Kind::Return;
            r.value = j["return"];
        } else if (j.contains("error")) {
            r.kind = QmpReply::Kind::Error;
            r.error_class = j["error"]["class"].as_string();
            r.error_desc = j["error"]["desc"].as_string();
        } else {
            continue;
        }
        out.push_back(std::move(r));
    }
    return out;
}

int64_t QmpSession::command(std::string_view name, const Json& args, std::string& outgoing) {
    int64_t id = next_id_++;
    Json cmd = Json::object();
    cmd.set("execute", std::string(name));
    if (!args.is_null()) cmd.set("arguments", args);
    cmd.set("id", static_cast<long long>(id));
    pending_[id] = std::string(name);
    std::string wire = cmd.dump() + "\r\n";
    if (state_ == State::Ready) {
        outgoing += wire;
    } else {
        queued_.push_back(std::move(wire));
    }
    return id;
}

void QmpSession::flush_queue(std::string& outgoing) {
    for (auto& q : queued_) outgoing += q;
    queued_.clear();
}

}  // namespace ideck
