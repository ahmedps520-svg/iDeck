#include "testing.hpp"

int main(int argc, char** argv) {
    return testing::run_all(argc > 1 ? argv[1] : nullptr);
}
