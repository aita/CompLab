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

project(minpython_cpp CXX)

# Default to an optimized build -- the JIT and the interpreter both want -O2.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD ON)   # partitions use `import std;`
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# No exceptions / RTTI (matching the sibling Smalltalk build). The frontend
# reports errors through a latched Diag instead of throwing, and xbyak is built
# in its XBYAK_NO_EXCEPTION mode (see jit.cppm).
add_compile_options(-fno-exceptions -fno-rtti)

# The interpreter + JIT are one module `minpython`, split into partitions that
# mirror the Python minpython/ layout. xbyak (the JIT assembler) is header-only
# and vendored under third_party/; it uses exceptions, so this project keeps them
# enabled (unlike the sibling Smalltalk build).
add_library(mp STATIC)
target_sources(mp
  PUBLIC
    FILE_SET CXX_MODULES FILES
      src/value.cppm
      src/bytecode.cppm
      src/lexer.cppm
      src/ast.cppm
      src/parser.cppm
      src/compiler.cppm
      src/vm.cppm
      src/regalloc.cppm
      src/jit.cppm
      src/method.cppm
      src/tiered.cppm
      src/minpython.cppm
)
target_include_directories(mp PUBLIC third_party)

add_executable(minpython src/main.cpp)
target_link_libraries(minpython PRIVATE mp)

add_executable(mp_bench bench/bench.cpp)
target_link_libraries(mp_bench PRIVATE mp)

enable_testing()
add_executable(mp_tests tests/test_minpython.cpp)
target_link_libraries(mp_tests PRIVATE mp)
add_test(NAME unit COMMAND mp_tests)
