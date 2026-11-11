#include "ideck/json.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace ideck {

namespace {

const Json kNull;
const std::string kEmptyString;
const Json::Array kEmptyArray;
const Json::Object kEmptyObject;

constexpr int kMaxDepth = 128;

struct Parser {
    std::string_view text;
    size_t pos = 0;
    std::string err;

    bool fail(const char* msg) {
        if (err.empty()) {
            err = msg;
            err += " at offset ";
            err += std::to_string(pos);
        }
        return false;
    }

    void skip_ws() {
        while (pos < text.size()) {
            char c = text[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++pos;
            } else {
                break;
            }
        }
    }

    bool literal(std::string_view word) {
        if (text.substr(pos, word.size()) == word) {
            pos += word.size();
            return true;
        }
        return fail("invalid literal");
    }

    static void append_utf8(uint32_t cp, std::string& out) {
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool hex4(uint32_t& out) {
        if (pos + 4 > text.size()) return fail("truncated \\u escape");
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) {
            char c = text[pos++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
            else return fail("invalid \\u escape");
        }
        out = v;
        return true;
    }

    bool string(std::string& out) {
        // Caller guarantees text[pos] == '"'.
        ++pos;
        while (true) {
            if (pos >= text.size()) return fail("unterminated string");
            unsigned char c = static_cast<unsigned char>(text[pos++]);
            if (c == '"') return true;
            if (c < 0x20) return fail("control character in string");
            if (c != '\\') {
                out.push_back(static_cast<char>(c));
                continue;
            }
            if (pos >= text.size()) return fail("unterminated escape");
            char e = text[pos++];
            switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    uint32_t cp = 0;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        // High surrogate: must be followed by a low surrogate.
                        if (pos + 1 < text.size() && text[pos] == '\\' && text[pos + 1] == 'u') {
                            pos += 2;
                            uint32_t lo = 0;
                            if (!hex4(lo)) return false;
                            if (lo < 0xDC00 || lo > 0xDFFF) return fail("invalid surrogate pair");
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        } else {
                            return fail("lone high surrogate");
                        }
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        return fail("lone low surrogate");
                    }
                    append_utf8(cp, out);
                    break;
                }
                default:
                    return fail("invalid escape");
            }
        }
    }

    bool number(Json& out) {
        size_t start = pos;
        bool is_int = true;
        if (pos < text.size() && text[pos] == '-') ++pos;
        if (pos >= text.size()) return fail("truncated number");
        if (text[pos] == '0') {
            ++pos;
        } else if (text[pos] >= '1' && text[pos] <= '9') {
            while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') ++pos;
        } else {
            return fail("invalid number");
        }
        if (pos < text.size() && text[pos] == '.') {
            is_int = false;
            ++pos;
            if (pos >= text.size() || text[pos] < '0' || text[pos] > '9') return fail("invalid fraction");
            while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') ++pos;
        }
        if (pos < text.size() && (text[pos] == 'e' || text[pos] == 'E')) {
            is_int = false;
            ++pos;
            if (pos < text.size() && (text[pos] == '+' || text[pos] == '-')) ++pos;
            if (pos >= text.size() || text[pos] < '0' || text[pos] > '9') return fail("invalid exponent");
            while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') ++pos;
        }
        std::string tok(text.substr(start, pos - start));
        if (is_int) {
            // Up to 18 digits always fits in int64; longer falls back to double.
            size_t digits = tok.size() - (tok[0] == '-' ? 1 : 0);
            if (digits <= 18) {
                out = Json(static_cast<long long>(std::strtoll(tok.c_str(), nullptr, 10)));
                return true;
            }
        }
        out = Json(std::strtod(tok.c_str(), nullptr));
        return true;
    }

    bool value(Json& out, int depth) {
        if (depth > kMaxDepth) return fail("nesting too deep");
        skip_ws();
        if (pos >= text.size()) return fail("unexpected end of input");
        char c = text[pos];
        switch (c) {
            case 'n':
                if (!literal("null")) return false;
                out = Json();
                return true;
            case 't':
                if (!literal("true")) return false;
                out = Json(true);
                return true;
            case 'f':
                if (!literal("false")) return false;
                out = Json(false);
                return true;
            case '"': {
                std::string s;
                if (!string(s)) return false;
                out = Json(std::move(s));
                return true;
            }
            case '[': {
                ++pos;
                out = Json::array();
                skip_ws();
                if (pos < text.size() && text[pos] == ']') {
                    ++pos;
                    return true;
                }
                while (true) {
                    Json item;
                    if (!value(item, depth + 1)) return false;
                    out.push(std::move(item));
                    skip_ws();
                    if (pos >= text.size()) return fail("unterminated array");
                    if (text[pos] == ',') {
                        ++pos;
                        continue;
                    }
                    if (text[pos] == ']') {
                        ++pos;
                        return true;
                    }
                    return fail("expected ',' or ']'");
                }
            }
            case '{': {
                ++pos;
                out = Json::object();
                skip_ws();
                if (pos < text.size() && text[pos] == '}') {
                    ++pos;
                    return true;
                }
                while (true) {
                    skip_ws();
                    if (pos >= text.size() || text[pos] != '"') return fail("expected object key");
                    std::string key;
                    if (!string(key)) return false;
                    skip_ws();
                    if (pos >= text.size() || text[pos] != ':') return fail("expected ':'");
                    ++pos;
                    Json item;
                    if (!value(item, depth + 1)) return false;
                    out.set(key, std::move(item));
                    skip_ws();
                    if (pos >= text.size()) return fail("unterminated object");
                    if (text[pos] == ',') {
                        ++pos;
                        continue;
                    }
                    if (text[pos] == '}') {
                        ++pos;
                        return true;
                    }
                    return fail("expected ',' or '}'");
                }
            }
            default:
                if (c == '-' || (c >= '0' && c <= '9')) return number(out);
                return fail("unexpected character");
        }
    }
};

}  // namespace

int64_t Json::as_int(int64_t def) const {
    if (type_ == Type::Int) return i_;
    if (type_ == Type::Double) return static_cast<int64_t>(d_);
    return def;
}

double Json::as_double(double def) const {
    if (type_ == Type::Double) return d_;
    if (type_ == Type::Int) return static_cast<double>(i_);
    return def;
}

const std::string& Json::as_string() const {
    return type_ == Type::String ? s_ : kEmptyString;
}

std::string Json::string_or(std::string_view def) const {
    return type_ == Type::String ? s_ : std::string(def);
}

const Json::Array& Json::items() const {
    return type_ == Type::Array ? a_ : kEmptyArray;
}

const Json::Object& Json::members() const {
    return type_ == Type::Object ? o_ : kEmptyObject;
}

size_t Json::size() const {
    if (type_ == Type::Array) return a_.size();
    if (type_ == Type::Object) return o_.size();
    return 0;
}

const Json* Json::find(std::string_view key) const {
    if (type_ != Type::Object) return nullptr;
    for (const auto& m : o_) {
        if (m.first == key) return &m.second;
    }
    return nullptr;
}

const Json& Json::operator[](std::string_view key) const {
    const Json* j = find(key);
    return j ? *j : kNull;
}

const Json& Json::at(size_t index) const {
    if (type_ != Type::Array || index >= a_.size()) return kNull;
    return a_[index];
}

Json& Json::set(std::string_view key, Json value) {
    if (type_ == Type::Null) type_ = Type::Object;
    if (type_ != Type::Object) return *this;
    for (auto& m : o_) {
        if (m.first == key) {
            m.second = std::move(value);
            return *this;
        }
    }
    o_.emplace_back(std::string(key), std::move(value));
    return *this;
}

Json& Json::push(Json value) {
    if (type_ == Type::Null) type_ = Type::Array;
    if (type_ != Type::Array) return *this;
    a_.push_back(std::move(value));
    return *this;
}

void json_escape(std::string_view s, std::string& out) {
    out.push_back('"');
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    out.push_back('"');
}

void Json::dump_to(std::string& out, int indent, int depth) const {
    auto newline = [&](int d) {
        if (indent < 0) return;
        out.push_back('\n');
        out.append(static_cast<size_t>(indent) * static_cast<size_t>(d), ' ');
    };
    switch (type_) {
        case Type::Null: out += "null"; break;
        case Type::Bool: out += b_ ? "true" : "false"; break;
        case Type::Int: out += std::to_string(i_); break;
        case Type::Double: {
            if (!std::isfinite(d_)) {
                out += "null";
                break;
            }
            char buf[40];
            std::snprintf(buf, sizeof(buf), "%.17g", d_);
            // Prefer the shortest representation that round-trips.
            for (int prec = 1; prec < 17; ++prec) {
                char trial[40];
                std::snprintf(trial, sizeof(trial), "%.*g", prec, d_);
                if (std::strtod(trial, nullptr) == d_) {
                    std::memcpy(buf, trial, sizeof(trial));
                    break;
                }
            }
            out += buf;
            // Keep doubles recognisable as doubles on re-parse.
            if (!std::strpbrk(buf, ".eE")) out += ".0";
            break;
        }
        case Type::String: json_escape(s_, out); break;
        case Type::Array: {
            if (a_.empty()) {
                out += "[]";
                break;
            }
            out.push_back('[');
            for (size_t i = 0; i < a_.size(); ++i) {
                if (i) out.push_back(',');
                newline(depth + 1);
                a_[i].dump_to(out, indent, depth + 1);
            }
            newline(depth);
            out.push_back(']');
            break;
        }
        case Type::Object: {
            if (o_.empty()) {
                out += "{}";
                break;
            }
            out.push_back('{');
            for (size_t i = 0; i < o_.size(); ++i) {
                if (i) out.push_back(',');
                newline(depth + 1);
                json_escape(o_[i].first, out);
                out.push_back(':');
                if (indent >= 0) out.push_back(' ');
                o_[i].second.dump_to(out, indent, depth + 1);
            }
            newline(depth);
            out.push_back('}');
            break;
        }
    }
}

std::string Json::dump(int indent) const {
    std::string out;
    dump_to(out, indent, 0);
    return out;
}

bool Json::parse(std::string_view text, Json& out, std::string* err) {
    Parser p;
    p.text = text;
    Json result;
    if (!p.value(result, 0)) {
        if (err) *err = p.err;
        return false;
    }
    p.skip_ws();
    if (p.pos != text.size()) {
        p.fail("trailing characters");
        if (err) *err = p.err;
        return false;
    }
    out = std::move(result);
    return true;
}

bool Json::operator==(const Json& o) const {
    if (is_number() && o.is_number()) {
        if (type_ == Type::Int && o.type_ == Type::Int) return i_ == o.i_;
        return as_double() == o.as_double();
    }
    if (type_ != o.type_) return false;
    switch (type_) {
        case Type::Null: return true;
        case Type::Bool: return b_ == o.b_;
        case Type::String: return s_ == o.s_;
        case Type::Array: return a_ == o.a_;
        case Type::Object: {
            if (o_.size() != o.o_.size()) return false;
            for (const auto& m : o_) {
                const Json* other = o.find(m.first);
                if (!other || *other != m.second) return false;
            }
            return true;
        }
        default: return false;
    }
}

}  // namespace ideck
