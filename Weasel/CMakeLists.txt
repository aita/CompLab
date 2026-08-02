cmake_minimum_required(VERSION 3.28)

# C++20 modules are exercised most reliably by clang++ here; prefer it for a
# fresh build tree unless the caller pins a compiler.
if(NOT DEFINED CMAKE_CXX_COMPILER AND NOT DEFINED ENV{CXX})
  find_program(_CLANGXX clang++)
  if(_CLANGXX)
    set(CMAKE_CXX_COMPILER "${_CLANGXX}")
  endif()
endif()

# Opt into CMake's (still experimental) `import std;` support. The UUID gates the
# feature and is specific to this CMake version; bump it if CMake is upgraded and
# complains. Must be set before the CXX language is enabled.
set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "451f2fe2-a8a2-47c3-bc32-94786d8fc91b")

project(weasel CXX)

# Default to an optimized build -- the interpreter loop wants -O2.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD ON)   # partitions use `import std;`
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# No exceptions / RTTI (matching the sibling rvemu and minpython-cpp builds).
# A validation failure travels through a latched Diag; a runtime failure travels
# through a latched Trap. Neither unwinds.
add_compile_options(-fno-exceptions -fno-rtti)

# Every float operation here is specified to the bit, so the optimizer must not
# reassociate, contract, or assume the default rounding environment.
add_compile_options(-ffp-contract=off -fno-fast-math)

# One module `weasel`, split into partitions.
add_library(weasel_lib STATIC)
set_target_properties(weasel_lib PROPERTIES OUTPUT_NAME weasel)
target_sources(weasel_lib
  PUBLIC
    FILE_SET CXX_MODULES FILES
      src/common.cppm
      src/opcode.cppm
      src/types.cppm
      src/binary.cppm
      src/text.cppm
      src/validate.cppm
      src/store.cppm
      src/instantiate.cppm
      src/dump.cppm
      src/exec.cppm
      src/wasi.cppm
      src/host.cppm
      src/weasel.cppm
)

add_executable(weasel src/main.cpp)
target_link_libraries(weasel PRIVATE weasel_lib)

enable_testing()
add_executable(weasel_tests tests/test_weasel.cpp)
target_link_libraries(weasel_tests PRIVATE weasel_lib)
target_compile_definitions(weasel_tests
  PRIVATE WEASEL_TEST_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
add_test(NAME unit COMMAND weasel_tests)
