cmake_minimum_required(VERSION 3.20)
project(dm_attestation LANGUAGES OBJCXX)

set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

add_library(dm_attestation STATIC
    src/dm_attestation.mm
)

target_include_directories(dm_attestation PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(dm_attestation PUBLIC
    "-framework Foundation"
    "-framework Security"
    "-framework DeviceCheck"
)

target_compile_options(dm_attestation PRIVATE -Wall -Wextra -Werror -O2 -fobjc-arc)

add_executable(dm_attestation_test
    tests/dm_attestation_test.mm
)
target_link_libraries(dm_attestation_test PRIVATE dm_attestation)
target_compile_options(dm_attestation_test PRIVATE -Wall -Wextra -Werror -O2 -fobjc-arc)
