// Tests: JSON, SHA-256, filesystem helpers.
#include <chrono>
#include <filesystem>
#include <random>
#include <string>
#include <vector>

#include "ideck/fsutil.hpp"
#include "ideck/json.hpp"
#include "ideck/sha256.hpp"
#include "testing.hpp"

using namespace ideck;
namespace fs = std::filesystem;

namespace {

std::string temp_dir(const char* tag) {
    auto base = fs::temp_directory_path();
    auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    auto p = base / (std::string("ideck-test-") + tag + "-" + std::to_string(stamp));
    fs::create_directories(p);
    return p.string();
}

}  // namespace

TEST("json: parses scalars and containers") {
    Json j;
    std::string err;
    CHECK(Json::parse(R"({"a":1,"b":[true,false,null],"c":"x","d":-2.5e3,"e":{}})", j, &err));
    CHECK_EQ(j["a"].as_int(), 1);
    CHECK(j["b"].is_array());
    CHECK_EQ(j["b"].size(), 3u);
    CHECK(j["b"].at(0).as_bool());
    CHECK(j["b"].at(2).is_null());
    CHECK_EQ(j["c"].as_string(), std::string("x"));
    CHECK_EQ(j["d"].as_double(), -2500.0);
    CHECK(j["e"].is_object());
    CHECK(j["missing"]["deeper"].is_null());
}

TEST("json: round trips through dump") {
    Json j = Json::object();
    j.set("name", "iDeck \"quoted\" \\ \n tab\t");
    j.set("n", 42);
    j.set("big", 1234567890123LL);
    j.set("f", 0.1);
    Json arr = Json::array();
    arr.push(1);
    arr.push("two");
    arr.push(Json());
    j.set("arr", arr);
    for (int indent : {-1, 2}) {
        Json back;
        std::string err;
        CHECK(Json::parse(j.dump(indent), back, &err));
        CHECK(back == j);
    }
    CHECK_EQ(Json(1.0).dump(), std::string("1.0"));
    CHECK_EQ(Json(0.1).dump(), std::string("0.1"));
}

TEST("json: unicode escapes and surrogate pairs") {
    Json j;
    CHECK(Json::parse(R"("café 🎮")", j));
    CHECK_EQ(j.as_string(), std::string("caf\xC3\xA9 \xF0\x9F\x8E\xAE"));
    CHECK(!Json::parse(R"("\ud83c")", j));
    CHECK(!Json::parse(R"("\udfae")", j));
}

TEST("json: rejects malformed input") {
    Json j;
    const char* bad[] = {"", "{", "[1,]", "{\"a\" 1}", "01", "1.", "tru", "\"\x01\"", "[1] x", "{\"a\":1,}", "-"};
    for (const char* b : bad) CHECK(!Json::parse(b, j));
    std::string deep(200, '[');
    CHECK(!Json::parse(deep, j));
}

TEST("json: large integers fall back to double") {
    Json j;
    CHECK(Json::parse("123456789012345678901234", j));
    CHECK(j.type() == Json::Type::Double);
    CHECK(Json::parse("-922337203685477580", j));
    CHECK(j.type() == Json::Type::Int);
}

TEST("sha256: FIPS 180-4 test vectors") {
    CHECK_EQ(sha256_hex(""), std::string("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    CHECK_EQ(sha256_hex("abc"), std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    CHECK_EQ(sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
             std::string("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
    std::string million(1000000, 'a');
    CHECK_EQ(sha256_hex(million), std::string("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));
}

TEST("sha256: streaming matches one-shot for every split") {
    std::string data;
    for (int i = 0; i < 300; ++i) data.push_back(static_cast<char>(i * 7 + 3));
    std::string expect = sha256_hex(data);
    for (size_t split = 0; split <= data.size(); split += 13) {
        Sha256 h;
        h.update(data.data(), split);
        h.update(data.data() + split, data.size() - split);
        auto d = h.finish();
        CHECK_EQ(to_hex(d.data(), d.size()), expect);
    }
}

TEST("fsutil: atomic write replaces content") {
    std::string dir = temp_dir("atomic");
    std::string p = dir + "/state.json";
    CHECK(write_file_atomic(p, "first"));
    CHECK(write_file_atomic(p, "second"));
    std::string back;
    CHECK(read_file(p, back));
    CHECK_EQ(back, std::string("second"));
    CHECK(!path_exists(p + ".tmp"));
    remove_path(dir);
}

TEST("fsutil: sparse writer reproduces data and skips zero blocks") {
    std::string dir = temp_dir("sparse");
    std::string p = dir + "/disk.img";
    std::vector<uint8_t> data(4096 * 10, 0);
    for (size_t i = 0; i < 4096; ++i) data[i] = static_cast<uint8_t>(i);        // block 0
    for (size_t i = 4096 * 5; i < 4096 * 5 + 100; ++i) data[i] = 0xAB;          // block 5
    // blocks 6..9 zero: trailing hole must still extend the file
    SparseWriter w(4096);
    CHECK(w.open(p));
    // Write in odd-sized pieces to exercise the partial-block path.
    size_t pos = 0;
    size_t chunk = 1000;
    while (pos < data.size()) {
        size_t n = std::min(chunk, data.size() - pos);
        CHECK(w.write(data.data() + pos, n));
        pos += n;
        chunk = chunk * 3 % 7001 + 1;
    }
    CHECK(w.finish());
    CHECK_EQ(w.bytes_skipped(), static_cast<uint64_t>(4096 * 8));
    std::string back;
    CHECK(read_file(p, back));
    CHECK_EQ(back.size(), data.size());
    CHECK(std::equal(back.begin(), back.end(), data.begin(),
                     [](char a, uint8_t b) { return static_cast<uint8_t>(a) == b; }));
    std::string h1, h2;
    CHECK(sha256_file(p, h1));
    CHECK_EQ(h1, sha256_hex(std::string(data.begin(), data.end())));
    remove_path(dir);
}

TEST("fsutil: sparse create, grow, refuse shrink, clone") {
    std::string dir = temp_dir("grow");
    std::string p = dir + "/data.img";
    CHECK(create_sparse_file(p, 64ull << 20));
    CHECK_EQ(file_size(p), static_cast<int64_t>(64ull << 20));
    CHECK(grow_file(p, 128ull << 20));
    CHECK_EQ(file_size(p), static_cast<int64_t>(128ull << 20));
    CHECK(!grow_file(p, 1ull << 20));
    CHECK(create_sparse_file(p, 1ull << 20));  // never shrinks
    CHECK_EQ(file_size(p), static_cast<int64_t>(128ull << 20));
    int64_t alloc = allocated_size(p);
    CHECK(alloc >= 0);
    CHECK(alloc < (64ll << 20));  // sparse: far less than logical size
    bool cow = true;
    CHECK(clone_file(p, dir + "/snap.img", &cow));
    CHECK_EQ(file_size(dir + "/snap.img"), static_cast<int64_t>(128ull << 20));
    CHECK(!clone_file(p, dir + "/snap.img"));  // refuses to overwrite
    CHECK(free_space(dir) > 0);
    remove_path(dir);
}
