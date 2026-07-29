# Brings in the two halves of ANTLR: the generator (a Java jar, run at build
# time) and the C++ runtime the generated parser links against.
#
# Both are downloaded on the first configure and cached under the build
# directory, so a clone of this repository needs only cmake, a C++ compiler and
# a JRE.

set(OTTER_ANTLR_VERSION 4.13.2)

find_package(Java REQUIRED COMPONENTS Runtime)

set(OTTER_ANTLR_JAR ${CMAKE_BINARY_DIR}/antlr-${OTTER_ANTLR_VERSION}-complete.jar)

if(NOT EXISTS ${OTTER_ANTLR_JAR})
    message(STATUS "Downloading the ANTLR ${OTTER_ANTLR_VERSION} generator")
    file(DOWNLOAD
        https://www.antlr.org/download/antlr-${OTTER_ANTLR_VERSION}-complete.jar
        ${OTTER_ANTLR_JAR}
        SHOW_PROGRESS
        STATUS antlr_jar_status)
    list(GET antlr_jar_status 0 antlr_jar_error)
    if(antlr_jar_error)
        file(REMOVE ${OTTER_ANTLR_JAR})
        list(GET antlr_jar_status 1 antlr_jar_message)
        message(FATAL_ERROR "Could not download the ANTLR jar: ${antlr_jar_message}")
    endif()
endif()

# The 4.13.2 runtime still asks for a cmake_minimum_required below 3.5, which
# cmake 4 refuses outright, so name a floor it will accept.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)

set(ANTLR4_INSTALL OFF CACHE BOOL "" FORCE)
set(ANTLR_BUILD_CPP_TESTS OFF CACHE BOOL "" FORCE)
set(ANTLR_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(ANTLR_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(WITH_DEMO OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(antlr4_runtime
    URL https://www.antlr.org/download/antlr4-cpp-runtime-${OTTER_ANTLR_VERSION}-source.zip
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(antlr4_runtime)

# The runtime is third-party code held to its own standards, not ours.
target_compile_options(antlr4_static PRIVATE -w)
target_include_directories(antlr4_static SYSTEM INTERFACE ${antlr4_runtime_SOURCE_DIR}/runtime/src)

# antlr_generate(<target> <grammar> <namespace>)
#
# Runs the generator over <grammar> and hangs the resulting sources off
# <target>, along with the include directory they live in.
function(antlr_generate target grammar namespace)
    get_filename_component(grammar_name ${grammar} NAME_WE)
    get_filename_component(grammar_path ${grammar} ABSOLUTE)
    set(output_dir ${CMAKE_CURRENT_BINARY_DIR}/generated)

    set(generated_sources
        ${output_dir}/${grammar_name}Lexer.cpp
        ${output_dir}/${grammar_name}Parser.cpp
        ${output_dir}/${grammar_name}BaseVisitor.cpp
        ${output_dir}/${grammar_name}Visitor.cpp)

    add_custom_command(
        OUTPUT ${generated_sources}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${output_dir}
        COMMAND ${Java_JAVA_EXECUTABLE} -jar ${OTTER_ANTLR_JAR}
                -Dlanguage=Cpp -visitor -no-listener
                -package ${namespace}
                -o ${output_dir}
                ${grammar_path}
        DEPENDS ${grammar_path} ${OTTER_ANTLR_JAR}
        COMMENT "Generating the ${grammar_name} lexer and parser"
        VERBATIM)

    target_sources(${target} PRIVATE ${generated_sources})
    target_include_directories(${target} PRIVATE ${output_dir})
    set_source_files_properties(${generated_sources} PROPERTIES COMPILE_OPTIONS -w)
endfunction()
