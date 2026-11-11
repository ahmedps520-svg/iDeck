// iDeck core — filesystem helpers used by the installer and storage manager.
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>

namespace ideck {

bool read_file(const std::string& path, std::string& out);

// Writes `data` to `path` atomically: temp file in the same directory,
// flushed (fsync on POSIX), then renamed over the destination. A crash leaves
// either the old or the new content, never a torn file.
bool write_file_atomic(const std::string& path, std::string_view data);

bool path_exists(const std::string& path);
bool make_dirs(const std::string& path);
bool remove_path(const std::string& path);  // file or directory tree
bool rename_path(const std::string& from, const std::string& to);

// Logical size in bytes, or -1.
int64_t file_size(const std::string& path);
// Bytes actually allocated on disk (sparse files report less than their
// logical size), or -1 if unknown.
int64_t allocated_size(const std::string& path);
// Free bytes available to an unprivileged process on the volume, or -1.
int64_t free_space(const std::string& path);

// Creates (or truncates up to) a sparse file of `size` bytes. Never shrinks.
bool create_sparse_file(const std::string& path, uint64_t size);
// Grows a file to `new_size`. Refuses to shrink (returns false).
bool grow_file(const std::string& path, uint64_t new_size);

// Copy-on-write clone where the filesystem supports it (APFS clonefile),
// falling back to a sparse-aware copy. Fails if `dst` exists.
bool clone_file(const std::string& src, const std::string& dst, bool* used_cow = nullptr);

// Writes a stream to a file, skipping all-zero blocks so the result stays
// sparse. Used when expanding compressed disk images.
class SparseWriter {
public:
    explicit SparseWriter(size_t block_size = 4096);
    ~SparseWriter();
    SparseWriter(const SparseWriter&) = delete;
    SparseWriter& operator=(const SparseWriter&) = delete;

    bool open(const std::string& path);
    bool write(const void* data, size_t len);
    // Flushes the partial block, sets the final logical size, closes.
    bool finish();
    uint64_t bytes_in() const { return offset_ + pending_len_; }
    uint64_t bytes_skipped() const { return skipped_; }

private:
    bool flush_block(const uint8_t* block, size_t len);

    std::FILE* f_ = nullptr;
    std::string path_;
    size_t block_size_;
    uint8_t* pending_ = nullptr;
    size_t pending_len_ = 0;
    uint64_t offset_ = 0;
    uint64_t skipped_ = 0;
    bool failed_ = false;
};

}  // namespace ideck
