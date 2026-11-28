cmake_minimum_required(VERSION 3.20)
project(dm_attestation LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(DM_ATTESTATION_WARN_FLAGS
    -fobjc-arc
    -Wall
    -Wextra
    -Werror
    -Wformat=2
    $<$<CONFIG:>:-O2>
)

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

target_compile_options(dm_attestation PRIVATE ${DM_ATTESTATION_WARN_FLAGS})

add_executable(dm_attestation_test
    tests/dm_attestation_test.mm
)
target_link_libraries(dm_attestation_test PRIVATE dm_attestation)
target_compile_options(dm_attestation_test PRIVATE ${DM_ATTESTATION_WARN_FLAGS})

enable_testing()
add_test(NAME dm_attestation_test COMMAND dm_attestation_test)
set_tests_properties(dm_attestation_test PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "DM_CTEST_ALLOW_SKIP=1"
)
