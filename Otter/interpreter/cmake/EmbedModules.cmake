# Turns the built-in modules into a C++ header, so that the interpreter carries
# them and `import io;` needs no file beside the program.
#
# Run in script mode:
#   cmake -DSOURCES=<paths joined by |> -DOUTPUT=<header> -P EmbedModules.cmake

set(delimiter "otter")
string(REPLACE "|" ";" sourceList "${SOURCES}")

set(entries "")
foreach(path IN LISTS sourceList)
    get_filename_component(name ${path} NAME_WE)
    file(READ ${path} content)

    # The contents go in verbatim as a raw string, so the one sequence that
    # would end it early has to be absent.
    string(FIND "${content}" ")${delimiter}\"" clash)
    if(NOT clash EQUAL -1)
        message(FATAL_ERROR "${path} contains )${delimiter}\", which would end the raw string")
    endif()

    # The contents start right after the opening paren, so that a position
    # reported inside one of these lines up with the file it came from.
    string(APPEND entries "    {\"${name}\", R\"${delimiter}(${content})${delimiter}\"},\n")
endforeach()

set(generated "// Generated from interpreter/modules by cmake. Do not edit.
//
// The built-in modules are ordinary Otter source, kept as ordinary files and
// embedded here at build time.

#pragma once

namespace otter::detail {

struct BuiltinModuleSource {
    const char* name;
    const char* source;
};

inline constexpr BuiltinModuleSource builtinModuleSources[] = {
${entries}};

}  // namespace otter::detail
")

# Leaving an unchanged header alone keeps the build from rewalking everything
# that includes it.
if(EXISTS ${OUTPUT})
    file(READ ${OUTPUT} previous)
    if(previous STREQUAL generated)
        return()
    endif()
endif()

file(WRITE ${OUTPUT} "${generated}")
