# Runs one program and compares what it wrote against the recorded transcript.
#
# The program is named relative to its own directory so that the file names in
# diagnostics do not depend on where the build tree sits.

execute_process(
    COMMAND ${OTTER} ${NAME}
    WORKING_DIRECTORY ${DIRECTORY}
    OUTPUT_VARIABLE actualOutput
    ERROR_VARIABLE actualError
    RESULT_VARIABLE actualStatus)

if(STREAM STREQUAL "stderr")
    set(actual "${actualError}")
else()
    set(actual "${actualOutput}")
endif()

file(READ ${EXPECTED} expected)

if(NOT actual STREQUAL expected)
    message(FATAL_ERROR
        "${NAME} wrote something else.\n"
        "---- expected ----\n${expected}"
        "---- actual ----\n${actual}"
        "---- exit status ${actualStatus} ----")
endif()

if(DEFINED STATUS AND NOT actualStatus STREQUAL STATUS)
    message(FATAL_ERROR "${NAME} exited with ${actualStatus}, not ${STATUS}")
endif()
