cmake_minimum_required(VERSION 3.30)

# `import std;` is still behind an experimental gate in CMake, keyed by a UUID
# that changes with the CMake version. This one is for CMake 4.3; bump it (see
# Help/dev/experimental.rst in the CMake sources) if the configure step reports
# the feature as unsupported. Must be set before `project()` enables CXX.
set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "451f2fe2-a8a2-47c3-bc32-94786d8fc91b")

# Prefer clang++ for a fresh build tree: GCC 16's C++20 modules currently fail
# to read this project's `st:vm` BMI ("Bad file data"). Override with
# -DCMAKE_CXX_COMPILER=... if you want a specific compiler.
if(NOT DEFINED CMAKE_CXX_COMPILER AND NOT DEFINED ENV{CXX})
  find_program(_CLANGXX clang++)
  if(_CLANGXX)
    set(CMAKE_CXX_COMPILER "${_CLANGXX}")
  endif()
endif()

project(smalltalk_cpp CXX)

# Default to an optimized build — without this CMake uses no -O flag (a ~10x
# slower debug build). Override with -DCMAKE_BUILD_TYPE=Debug.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Every translation unit says `import std;` instead of including headers, so the
# standard library module has to be built for us. Needs Ninja plus a toolchain
# that ships a modules manifest (clang with libc++/libstdc++, or GCC 15+).
set(CMAKE_CXX_MODULE_STD 1)
if(NOT "23" IN_LIST CMAKE_CXX_COMPILER_IMPORT_STD)
  message(FATAL_ERROR
    "This build needs `import std;` support: "
    "${CMAKE_CXX_COMPILER_IMPORT_STD_ERROR_MESSAGE}")
endif()

# Emit build/compile_commands.json so clangd (Zed / VS Code) knows the flags.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Constraints for this implementation: no reference counting and restricted
# exception use. Build without exceptions/RTTI so the constraint is enforced.
add_compile_options(-fno-exceptions -fno-rtti)

# The interpreter is one module `st`, split into partitions that mirror the
# Python `st/` layout. New partitions go in the CXX_MODULES file set below.
add_library(st STATIC)
target_sources(st
  PUBLIC
    FILE_SET CXX_MODULES FILES
      src/bytecode.cppm
      src/objects.cppm
      src/heap.cppm
      src/lexer.cppm
      src/ast.cppm
      src/parser.cppm
      src/compiler.cppm
      src/vm.cppm
      src/kernel.cppm
      src/system.cppm
      src/st.cppm
)

add_executable(smalltalk src/main.cpp)
target_link_libraries(smalltalk PRIVATE st)

add_executable(st_bench bench/bench.cpp)
target_link_libraries(st_bench PRIVATE st)

enable_testing()
add_executable(st_tests tests/test_lexer.cpp)
target_link_libraries(st_tests PRIVATE st)
add_test(NAME unit COMMAND st_tests)
