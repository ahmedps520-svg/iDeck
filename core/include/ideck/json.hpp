// iDeck core — minimal JSON value, parser and serializer.
//
// Used for QMP, the guest agent protocol, runtime manifests and the install
// journal. Kept dependency-free so the same code builds for iOS, the Linux
// guest (static musl) and the desktop test hosts.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace ideck {

class Json {
public:
    enum class Type : uint8_t { Null, Bool, Int, Double, String, Array, Object };
    using Array = std::vector<Json>;
    using Member = std::pair<std::string, Json>;
    using Object = std::vector<Member>;  // insertion-ordered

    Json() = default;
    Json(std::nullptr_t) {}
    Json(bool v) : type_(Type::Bool), b_(v) {}
    Json(int v) : type_(Type::Int), i_(v) {}
    Json(unsigned v) : type_(Type::Int), i_(static_cast<int64_t>(v)) {}
    Json(long v) : type_(Type::Int), i_(static_cast<int64_t>(v)) {}
    Json(unsigned long v) : type_(Type::Int), i_(static_cast<int64_t>(v)) {}
    Json(long long v) : type_(Type::Int), i_(static_cast<int64_t>(v)) {}
    Json(unsigned long long v) : type_(Type::Int), i_(static_cast<int64_t>(v)) {}
    Json(double v) : type_(Type::Double), d_(v) {}
    Json(const char* s) : type_(Type::String), s_(s ? s : "") {}
    Json(std::string s) : type_(Type::String), s_(std::move(s)) {}
    Json(std::string_view s) : type_(Type::String), s_(s) {}

    static Json array() { Json j; j.type_ = Type::Array; return j; }
    static Json object() { Json j; j.type_ = Type::Object; return j; }

    Type type() const { return type_; }
    bool is_null() const { return type_ == Type::Null; }
    bool is_bool() const { return type_ == Type::Bool; }
    bool is_number() const { return type_ == Type::Int || type_ == Type::Double; }
    bool is_string() const { return type_ == Type::String; }
    bool is_array() const { return type_ == Type::Array; }
    bool is_object() const { return type_ == Type::Object; }

    bool as_bool(bool def = false) const { return type_ == Type::Bool ? b_ : def; }
    int64_t as_int(int64_t def = 0) const;
    double as_double(double def = 0.0) const;
    const std::string& as_string() const;
    std::string string_or(std::string_view def) const;

    const Array& items() const;
    const Object& members() const;
    size_t size() const;

    // Object lookup. Returns a shared Null value when the key is missing or
    // this is not an object, so lookups can be chained safely.
    const Json& operator[](std::string_view key) const;
    const Json* find(std::string_view key) const;
    bool contains(std::string_view key) const { return find(key) != nullptr; }
    // Array lookup; shared Null when out of range.
    const Json& at(size_t index) const;

    // Mutators. `set` turns a Null value into an object, `push` into an array.
    Json& set(std::string_view key, Json value);
    Json& push(Json value);

    // indent < 0: compact single line. indent >= 0: pretty-printed.
    std::string dump(int indent = -1) const;

    static bool parse(std::string_view text, Json& out, std::string* err = nullptr);

    bool operator==(const Json& o) const;
    bool operator!=(const Json& o) const { return !(*this == o); }

private:
    void dump_to(std::string& out, int indent, int depth) const;

    Type type_ = Type::Null;
    bool b_ = false;
    int64_t i_ = 0;
    double d_ = 0.0;
    std::string s_;
    Array a_;
    Object o_;
};

// Appends `s` to `out` as a JSON string literal (with quotes).
void json_escape(std::string_view s, std::string& out);

}  // namespace ideck
