#include "ideck/manifest.hpp"

#include <cstdlib>
#include <set>

namespace ideck {

namespace {

std::vector<long long> version_parts(const std::string& v) {
    std::vector<long long> parts;
    std::string core = v.substr(0, v.find('-'));
    if (!core.empty() && (core[0] == 'v' || core[0] == 'V')) core.erase(0, 1);
    size_t start = 0;
    while (start <= core.size()) {
        size_t dot = core.find('.', start);
        std::string seg = core.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        parts.push_back(seg.empty() ? 0 : std::strtoll(seg.c_str(), nullptr, 10));
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    while (parts.size() > 1 && parts.back() == 0) parts.pop_back();
    return parts;
}

const std::set<std::string> kRoles = {"kernel", "initrd", "system-disk", "component"};
const std::set<std::string> kCompression = {"", "xz", "lzfse", "zlib"};

}  // namespace

int compare_versions(const std::string& a, const std::string& b) {
    auto pa = version_parts(a);
    auto pb = version_parts(b);
    size_t n = pa.size() > pb.size() ? pa.size() : pb.size();
    for (size_t i = 0; i < n; ++i) {
        long long x = i < pa.size() ? pa[i] : 0;
        long long y = i < pb.size() ? pb[i] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

bool is_valid_sha256_hex(const std::string& s) {
    if (s.size() != 64) return false;
    for (char c : s) {
        bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) return false;
    }
    return true;
}

bool is_safe_file_name(const std::string& s) {
    if (s.empty() || s.size() > 128) return false;
    if (s == "." || s == "..") return false;
    for (char c : s) {
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                  c == '.' || c == '-' || c == '_';
        if (!ok) return false;
    }
    return s[0] != '.';
}

const Artifact* Manifest::find_role(const std::string& role) const {
    for (const auto& a : artifacts) {
        if (a.role == role) return &a;
    }
    return nullptr;
}

const Artifact* Manifest::find_id(const std::string& id) const {
    for (const auto& a : artifacts) {
        if (a.id == id) return &a;
    }
    return nullptr;
}

uint64_t Manifest::total_download_size() const {
    uint64_t t = 0;
    for (const auto& a : artifacts) t += a.size;
    return t;
}

uint64_t Manifest::total_installed_size() const {
    uint64_t t = 0;
    for (const auto& a : artifacts) t += a.installed_size ? a.installed_size : a.size;
    return t;
}

bool parse_manifest(const std::string& text, Manifest& out, std::vector<std::string>& errors) {
    errors.clear();
    Json j;
    std::string perr;
    if (!Json::parse(text, j, &perr)) {
        errors.push_back("manifest is not valid JSON: " + perr);
        return false;
    }
    if (!j.is_object()) {
        errors.push_back("manifest root must be an object");
        return false;
    }
    Manifest m;
    m.schema = static_cast<int>(j["schema"].as_int(0));
    if (m.schema != 1) errors.push_back("unsupported manifest schema " + std::to_string(m.schema));
    m.runtime_version = j["runtime_version"].as_string();
    if (m.runtime_version.empty()) errors.push_back("runtime_version is required");
    m.channel = j["channel"].string_or("stable");
    m.min_app_build = static_cast<int>(j["min_app_build"].as_int(0));
    m.kernel_cmdline = j["kernel_cmdline"].as_string();
    m.guest = j["guest"];
    m.defaults = j["defaults"];

    if (!j["artifacts"].is_array() || j["artifacts"].size() == 0) {
        errors.push_back("artifacts must be a non-empty array");
    }
    std::set<std::string> ids, files;
    for (const auto& aj : j["artifacts"].items()) {
        Artifact a;
        a.id = aj["id"].as_string();
        a.role = aj["role"].as_string();
        a.file = aj["file"].as_string();
        a.url = aj["url"].as_string();
        a.sha256 = aj["sha256"].as_string();
        a.size = static_cast<uint64_t>(aj["size"].as_int(0));
        a.compression = aj["compression"].as_string();
        a.installed_size = static_cast<uint64_t>(aj["installed_size"].as_int(0));
        a.installed_sha256 = aj["installed_sha256"].as_string();
        a.sparse = aj["sparse"].as_bool(false);

        std::string where = "artifact '" + a.id + "': ";
        if (a.id.empty()) errors.push_back("artifact without id");
        if (!ids.insert(a.id).second) errors.push_back(where + "duplicate id");
        if (!kRoles.count(a.role)) errors.push_back(where + "unknown role '" + a.role + "'");
        if (!is_safe_file_name(a.file)) errors.push_back(where + "unsafe file name '" + a.file + "'");
        if (!files.insert(a.file).second) errors.push_back(where + "duplicate file name");
        if (a.url.rfind("https://", 0) != 0) errors.push_back(where + "url must use https");
        if (!is_valid_sha256_hex(a.sha256)) errors.push_back(where + "sha256 must be 64 lowercase hex chars");
        if (a.size == 0) errors.push_back(where + "size must be > 0");
        if (!kCompression.count(a.compression)) errors.push_back(where + "unsupported compression '" + a.compression + "'");
        if (!a.compression.empty()) {
            if (a.installed_size == 0) errors.push_back(where + "compressed artifacts need installed_size");
            if (!is_valid_sha256_hex(a.installed_sha256))
                errors.push_back(where + "compressed artifacts need installed_sha256");
        } else if (!a.installed_sha256.empty() && a.installed_sha256 != a.sha256) {
            errors.push_back(where + "installed_sha256 differs from sha256 without compression");
        }
        m.artifacts.push_back(std::move(a));
    }
    for (const char* required : {"kernel", "system-disk"}) {
        int count = 0;
        for (const auto& a : m.artifacts) count += a.role == required;
        if (count != 1) errors.push_back(std::string("exactly one '") + required + "' artifact is required");
    }
    int initrds = 0;
    for (const auto& a : m.artifacts) initrds += a.role == "initrd";
    if (initrds > 1) errors.push_back("at most one 'initrd' artifact is allowed");

    if (!errors.empty()) return false;
    out = std::move(m);
    return true;
}

Json manifest_to_json(const Manifest& m) {
    Json j = Json::object();
    j.set("schema", m.schema);
    j.set("runtime_version", m.runtime_version);
    j.set("channel", m.channel);
    j.set("min_app_build", m.min_app_build);
    j.set("kernel_cmdline", m.kernel_cmdline);
    j.set("guest", m.guest);
    j.set("defaults", m.defaults);
    Json arr = Json::array();
    for (const auto& a : m.artifacts) {
        Json aj = Json::object();
        aj.set("id", a.id);
        aj.set("role", a.role);
        aj.set("file", a.file);
        aj.set("url", a.url);
        aj.set("sha256", a.sha256);
        aj.set("size", a.size);
        if (!a.compression.empty()) {
            aj.set("compression", a.compression);
            aj.set("installed_size", a.installed_size);
            aj.set("installed_sha256", a.installed_sha256);
        }
        if (a.sparse) aj.set("sparse", true);
        arr.push(std::move(aj));
    }
    j.set("artifacts", std::move(arr));
    return j;
}

}  // namespace ideck
