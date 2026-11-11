// iDeck core — streaming SHA-256 (FIPS 180-4).
//
// Every artifact the installer downloads is verified against the digest in
// the runtime manifest before it is committed.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>

namespace ideck {

class Sha256 {
public:
    Sha256();
    void update(const void* data, size_t len);
    // Finalises and returns the digest. The object must not be reused after.
    std::array<uint8_t, 32> finish();

private:
    void compress(const uint8_t* block);

    uint32_t state_[8];
    uint64_t total_len_ = 0;
    uint8_t buffer_[64];
    size_t buffer_len_ = 0;
};

std::string to_hex(const uint8_t* data, size_t len);
std::string sha256_hex(std::string_view data);

// Hashes a file in 1 MiB chunks. `progress(bytes_done)` may return false to
// cancel. Returns false on I/O error or cancellation.
bool sha256_file(const std::string& path, std::string& hex_out,
                 const std::function<bool(uint64_t)>& progress = nullptr);

}  // namespace ideck
