#include "ideck/fsutil.hpp"

#include <cstring>
#include <filesystem>
#include <system_error>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <io.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if defined(__APPLE__)
#include <sys/clonefile.h>
#endif

namespace fs = std::filesystem;

namespace ideck {

namespace {

bool seek64(std::FILE* f, uint64_t off) {
#if defined(_WIN32)
    return _fseeki64(f, static_cast<__int64>(off), SEEK_SET) == 0;
#else
    return fseeko(f, static_cast<off_t>(off), SEEK_SET) == 0;
#endif
}

bool flush_to_disk(std::FILE* f) {
    if (std::fflush(f) != 0) return false;
#if defined(_WIN32)
    return _commit(_fileno(f)) == 0;
#elif defined(__APPLE__)
    // fsync on Darwin does not force the drive cache; F_FULLFSYNC does.
    int fd = fileno(f);
    if (fcntl(fd, F_FULLFSYNC) == 0) return true;
    return fsync(fd) == 0;
#else
    return fsync(fileno(f)) == 0;
#endif
}

bool all_zero(const uint8_t* p, size_t n) {
    // Word-at-a-time scan; buffers are block-sized so this is hot.
    size_t i = 0;
    for (; i + sizeof(uint64_t) <= n; i += sizeof(uint64_t)) {
        uint64_t w;
        std::memcpy(&w, p + i, sizeof(w));
        if (w != 0) return false;
    }
    for (; i < n; ++i) {
        if (p[i] != 0) return false;
    }
    return true;
}

}  // namespace

bool read_file(const std::string& path, std::string& out) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    out.clear();
    char buf[65536];
    while (true) {
        size_t n = std::fread(buf, 1, sizeof(buf), f);
        out.append(buf, n);
        if (n < sizeof(buf)) break;
    }
    bool ok = !std::ferror(f);
    std::fclose(f);
    return ok;
}

bool write_file_atomic(const std::string& path, std::string_view data) {
    std::string tmp = path + ".tmp";
    std::FILE* f = std::fopen(tmp.c_str(), "wb");
    if (!f) return false;
    bool ok = std::fwrite(data.data(), 1, data.size(), f) == data.size();
    ok = flush_to_disk(f) && ok;
    ok = (std::fclose(f) == 0) && ok;
    if (!ok) {
        std::remove(tmp.c_str());
        return false;
    }
    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) {
        std::remove(tmp.c_str());
        return false;
    }
    return true;
}

bool path_exists(const std::string& path) {
    std::error_code ec;
    return fs::exists(path, ec);
}

bool make_dirs(const std::string& path) {
    std::error_code ec;
    fs::create_directories(path, ec);
    return !ec && fs::is_directory(path, ec);
}

bool remove_path(const std::string& path) {
    std::error_code ec;
    fs::remove_all(path, ec);
    return !ec;
}

bool rename_path(const std::string& from, const std::string& to) {
    std::error_code ec;
    fs::rename(from, to, ec);
    return !ec;
}

int64_t file_size(const std::string& path) {
    std::error_code ec;
    auto s = fs::file_size(path, ec);
    if (ec) return -1;
    return static_cast<int64_t>(s);
}

int64_t allocated_size(const std::string& path) {
#if defined(_WIN32)
    std::wstring w = fs::path(path).wstring();
    DWORD high = 0;
    DWORD low = GetCompressedFileSizeW(w.c_str(), &high);
    if (low == INVALID_FILE_SIZE && GetLastError() != NO_ERROR) return -1;
    return (static_cast<int64_t>(high) << 32) | low;
#else
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return -1;
    return static_cast<int64_t>(st.st_blocks) * 512;
#endif
}

int64_t free_space(const std::string& path) {
    std::error_code ec;
    auto info = fs::space(path, ec);
    if (ec) return -1;
    return static_cast<int64_t>(info.available);
}

bool create_sparse_file(const std::string& path, uint64_t size) {
    std::error_code ec;
    if (!fs::exists(path, ec)) {
        std::FILE* f = std::fopen(path.c_str(), "wb");
        if (!f) return false;
        std::fclose(f);
#if defined(_WIN32)
        // Mark the file sparse on NTFS so truncation does not allocate.
        std::wstring w = fs::path(path).wstring();
        HANDLE h = CreateFileW(w.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD ret = 0;
            DeviceIoControl(h, FSCTL_SET_SPARSE, nullptr, 0, nullptr, 0, &ret, nullptr);
            CloseHandle(h);
        }
#endif
    }
    auto cur = fs::file_size(path, ec);
    if (ec) return false;
    if (cur >= size) return true;
    fs::resize_file(path, size, ec);
    return !ec;
}

bool grow_file(const std::string& path, uint64_t new_size) {
    std::error_code ec;
    auto cur = fs::file_size(path, ec);
    if (ec || new_size < cur) return false;
    if (new_size == cur) return true;
    fs::resize_file(path, new_size, ec);
    return !ec;
}

bool clone_file(const std::string& src, const std::string& dst, bool* used_cow) {
    if (used_cow) *used_cow = false;
    if (path_exists(dst)) return false;
#if defined(__APPLE__)
    if (clonefile(src.c_str(), dst.c_str(), 0) == 0) {
        if (used_cow) *used_cow = true;
        return true;
    }
#endif
    std::FILE* in = std::fopen(src.c_str(), "rb");
    if (!in) return false;
    SparseWriter w(64 * 1024);
    if (!w.open(dst)) {
        std::fclose(in);
        return false;
    }
    std::vector<uint8_t> buf(1 << 20);
    bool ok = true;
    while (true) {
        size_t n = std::fread(buf.data(), 1, buf.size(), in);
        if (n > 0 && !w.write(buf.data(), n)) {
            ok = false;
            break;
        }
        if (n < buf.size()) {
            if (std::ferror(in)) ok = false;
            break;
        }
    }
    std::fclose(in);
    ok = w.finish() && ok;
    if (!ok) remove_path(dst);
    return ok;
}

SparseWriter::SparseWriter(size_t block_size) : block_size_(block_size ? block_size : 4096) {
    pending_ = new uint8_t[block_size_];
}

SparseWriter::~SparseWriter() {
    if (f_) std::fclose(f_);
    delete[] pending_;
}

bool SparseWriter::open(const std::string& path) {
    path_ = path;
    f_ = std::fopen(path.c_str(), "wb");
    if (!f_) return false;
#if defined(_WIN32)
    HANDLE h = reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(f_)));
    if (h != INVALID_HANDLE_VALUE) {
        DWORD ret = 0;
        DeviceIoControl(h, FSCTL_SET_SPARSE, nullptr, 0, nullptr, 0, &ret, nullptr);
    }
#endif
    offset_ = 0;
    skipped_ = 0;
    pending_len_ = 0;
    failed_ = false;
    return true;
}

bool SparseWriter::flush_block(const uint8_t* block, size_t len) {
    if (all_zero(block, len)) {
        offset_ += len;
        skipped_ += len;
        return true;
    }
    if (!seek64(f_, offset_)) return false;
    if (std::fwrite(block, 1, len, f_) != len) return false;
    offset_ += len;
    return true;
}

bool SparseWriter::write(const void* data, size_t len) {
    if (!f_ || failed_) return false;
    const uint8_t* p = static_cast<const uint8_t*>(data);
    if (pending_len_ > 0) {
        size_t take = block_size_ - pending_len_;
        if (take > len) take = len;
        std::memcpy(pending_ + pending_len_, p, take);
        pending_len_ += take;
        p += take;
        len -= take;
        if (pending_len_ == block_size_) {
            if (!flush_block(pending_, block_size_)) return !(failed_ = true);
            pending_len_ = 0;
        }
    }
    while (len >= block_size_) {
        if (!flush_block(p, block_size_)) return !(failed_ = true);
        p += block_size_;
        len -= block_size_;
    }
    if (len > 0) {
        std::memcpy(pending_, p, len);
        pending_len_ = len;
    }
    return true;
}

bool SparseWriter::finish() {
    if (!f_) return false;
    bool ok = !failed_;
    if (ok && pending_len_ > 0) {
        ok = flush_block(pending_, pending_len_);
        pending_len_ = 0;
    }
    ok = flush_to_disk(f_) && ok;
    ok = (std::fclose(f_) == 0) && ok;
    f_ = nullptr;
    if (ok) {
        // Trailing zero blocks were skipped; extend to the true length.
        std::error_code ec;
        auto cur = fs::file_size(path_, ec);
        if (ec) return false;
        if (cur < offset_) {
            fs::resize_file(path_, offset_, ec);
            if (ec) return false;
        }
    }
    return ok;
}

}  // namespace ideck
