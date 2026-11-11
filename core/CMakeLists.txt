cmake_minimum_required(VERSION 3.20)
project(ideck_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

file(GLOB IDECK_CORE_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp)

add_library(ideck_core STATIC ${IDECK_CORE_SOURCES})
target_include_directories(ideck_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
if(MSVC)
  target_compile_options(ideck_core PRIVATE /W4)
else()
  target_compile_options(ideck_core PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

add_library(ideck_core_shared SHARED ${IDECK_CORE_SOURCES})
target_include_directories(ideck_core_shared PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
set_target_properties(ideck_core_shared PROPERTIES OUTPUT_NAME ideck_core)

enable_testing()
file(GLOB IDECK_TEST_SOURCES CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/tests/*.cpp)
add_executable(ideck_core_tests ${IDECK_TEST_SOURCES})
target_link_libraries(ideck_core_tests PRIVATE ideck_core)
add_test(NAME ideck_core_tests COMMAND ideck_core_tests)
