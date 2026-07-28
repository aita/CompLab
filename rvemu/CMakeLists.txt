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

project(rvemu CXX)

# Default to an optimized build -- the interpreter loop wants -O2.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD ON)   # partitions use `import std;`
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# No exceptions / RTTI (matching the sibling minpython-cpp and Smalltalk builds).
# Errors travel through a latched Diag instead of throwing.
add_compile_options(-fno-exceptions -fno-rtti)

# The float unit reads and writes the host FPU's rounding mode and exception
# flags, so the optimizer must not assume the default environment.
add_compile_options(-ffp-contract=off -fno-fast-math)

# One module `rvemu`, split into partitions.
add_library(rvemu_lib STATIC)
set_target_properties(rvemu_lib PROPERTIES OUTPUT_NAME rvemu)
target_sources(rvemu_lib
  PUBLIC
    FILE_SET CXX_MODULES FILES
      src/common.cppm
      src/memory.cppm
      src/cpu.cppm
      src/decode.cppm
      src/disasm.cppm
      src/exec.cppm
      src/elf.cppm
      src/syscall.cppm
      src/assembler.cppm
      src/machine.cppm
      src/gdbstub.cppm
      src/rvemu.cppm
)

add_executable(rvemu src/main.cpp)
target_link_libraries(rvemu PRIVATE rvemu_lib)

enable_testing()
add_executable(rvemu_tests tests/test_rvemu.cpp)
target_link_libraries(rvemu_tests PRIVATE rvemu_lib)
add_test(NAME unit COMMAND rvemu_tests)
