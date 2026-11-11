// Minimal self-registering test harness (no external dependencies, so the
// suite builds with any C++17 toolchain, including cross compilers).
#pragma once

#include <cstdio>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace testing {

struct Case {
    const char* name;
    std::function<void()> fn;
};

inline std::vector<Case>& registry() {
    static std::vector<Case> r;
    return r;
}

inline int& failures() {
    static int f = 0;
    return f;
}

inline int& checks() {
    static int c = 0;
    return c;
}

struct Registrar {
    Registrar(const char* name, std::function<void()> fn) { registry().push_back({name, std::move(fn)}); }
};

template <typename A, typename B>
inline void check_eq(const A& a, const B& b, const char* ea, const char* eb, const char* file, int line) {
    ++checks();
    if (!(a == b)) {
        ++failures();
        std::ostringstream os;
        os << a << " != " << b;
        std::fprintf(stderr, "  FAIL %s:%d: %s == %s (%s)\n", file, line, ea, eb, os.str().c_str());
    }
}

inline void check(bool ok, const char* expr, const char* file, int line) {
    ++checks();
    if (!ok) {
        ++failures();
        std::fprintf(stderr, "  FAIL %s:%d: %s\n", file, line, expr);
    }
}

inline int run_all(const char* filter) {
    int ran = 0;
    for (const auto& c : registry()) {
        if (filter && std::string(c.name).find(filter) == std::string::npos) continue;
        int before = failures();
        c.fn();
        ++ran;
        std::printf("%s %s\n", failures() == before ? "  ok  " : "  FAIL", c.name);
    }
    std::printf("\n%d tests, %d checks, %d failures\n", ran, checks(), failures());
    return failures() == 0 ? 0 : 1;
}

}  // namespace testing

#define TEST_CAT2(a, b) a##b
#define TEST_CAT(a, b) TEST_CAT2(a, b)
#define TEST(name)                                                                       \
    static void TEST_CAT(test_fn_, __LINE__)();                                          \
    static ::testing::Registrar TEST_CAT(test_reg_, __LINE__)(name, TEST_CAT(test_fn_, __LINE__)); \
    static void TEST_CAT(test_fn_, __LINE__)()

#define CHECK(expr) ::testing::check((expr), #expr, __FILE__, __LINE__)
#define CHECK_EQ(a, b) ::testing::check_eq((a), (b), #a, #b, __FILE__, __LINE__)
