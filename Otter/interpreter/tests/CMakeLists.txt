# Each test is a program and a transcript of what running it should write.
#
# `cases/` holds programs that run to completion and are compared on their
# standard output; `errors/` holds programs that must be rejected or must fault,
# and are compared on their diagnostics.

# A test exists for every transcript, so adding one is a matter of writing the
# program and recording what it should say.
function(otter_tests directory prefix stream status)
    file(GLOB transcripts RELATIVE ${directory} ${directory}/*.expected)
    foreach(entry IN LISTS transcripts)
        get_filename_component(name ${entry} NAME_WE)
        add_test(NAME ${prefix}${name}
            COMMAND ${CMAKE_COMMAND}
                -DOTTER=$<TARGET_FILE:otter>
                -DDIRECTORY=${directory}
                -DNAME=${name}.otter
                -DEXPECTED=${directory}/${name}.expected
                -DSTREAM=${stream}
                -DSTATUS=${status}
                -P ${CMAKE_CURRENT_SOURCE_DIR}/run-case.cmake)
    endforeach()
endfunction()

otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/cases "" stdout 0)
otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/errors "" stderr 1)

# The examples are documentation, so they are held to running as well.
otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/../examples "example-" stdout 0)
