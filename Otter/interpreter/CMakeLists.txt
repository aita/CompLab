cmake_minimum_required(VERSION 3.30)

# `import std` is still behind an opt-in gate in cmake; this uuid is the one
# cmake 4.3 asks for.
set(CMAKE_EXPERIMENTAL_CXX_IMPORT_STD "451f2fe2-a8a2-47c3-bc32-94786d8fc91b")

project(otter CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_MODULE_STD ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(Antlr)

add_executable(otter src/main.cpp)

target_sources(otter PRIVATE FILE_SET CXX_MODULES FILES
    src/diagnostics.cppm
    src/types.cppm
    src/ast.cppm
    src/parse.cppm
    src/value.cppm
    src/builtins.cppm
    src/program.cppm
    src/check.cppm
    src/interp.cppm
)

antlr_generate(otter ${CMAKE_CURRENT_SOURCE_DIR}/grammar/Otter.g4 otter::grammar)

target_link_libraries(otter PRIVATE antlr4_static)
target_compile_options(otter PRIVATE -Wall -Wextra)

enable_testing()
add_subdirectory(tests)
