// iDeck core — runtime manifest.
//
// The runtime (kernel, initrd, system disk, guest components) is published by
// CI as a set of artifacts described by manifest.json. The installer only
// accepts artifacts listed here, fetched over HTTPS, and matching sha256.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "ideck/json.hpp"

namespace ideck {

// Compares dotted numeric versions ("1.10.2" > "1.9"). Non-numeric suffixes
// after '-' are ignored for ordering. Returns <0, 0, >0.
int compare_versions(const std::string& a, const std::string& b);

struct Artifact {
    std::string id;           // unique, e.g. "kernel"
    std::string role;         // kernel | initrd | system-disk | component
    std::string file;         // installed file name (no directories)
    std::string url;          // https:// only
    std::string sha256;       // of the downloaded (possibly compressed) bytes
    uint64_t size = 0;        // downloaded size
    std::string compression;  // "" | "xz" | "lzfse" | "zlib"
    uint64_t installed_size = 0;      // after decompression
    std::string installed_sha256;     // after decompression ("" = same as sha256)
    bool sparse = false;      // expand with SparseWriter
};

struct Manifest {
    int schema = 0;
    std::string runtime_version;
    std::string channel;
    int min_app_build = 0;
    std::string kernel_cmdline;
    Json guest;     // informational: distro, kernel version, mesa, fex...
    Json defaults;  // default VM config overrides
    std::vector<Artifact> artifacts;

    const Artifact* find_role(const std::string& role) const;
    const Artifact* find_id(const std::string& id) const;
    uint64_t total_download_size() const;
    uint64_t total_installed_size() const;
};

// Parses and validates. On failure returns false and fills `errors`.
bool parse_manifest(const std::string& text, Manifest& out, std::vector<std::string>& errors);
Json manifest_to_json(const Manifest& m);

bool is_valid_sha256_hex(const std::string& s);
bool is_safe_file_name(const std::string& s);

}  // namespace ideck
