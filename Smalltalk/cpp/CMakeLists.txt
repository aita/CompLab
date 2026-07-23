cmake_minimum_required(VERSION 3.28)

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

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

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

enable_testing()
add_executable(st_tests tests/test_lexer.cpp)
target_link_libraries(st_tests PRIVATE st)
add_test(NAME unit COMMAND st_tests)
