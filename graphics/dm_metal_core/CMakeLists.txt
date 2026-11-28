cmake_minimum_required(VERSION 3.20)
project(dm_metal_core LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(DM_METAL_CORE_WARN_FLAGS
    -fobjc-arc
    -Wall
    -Wextra
    -Werror
    -Wformat=2
    $<$<CONFIG:>:-O2>
)

add_library(dm_metal_core STATIC
    src/dm_metal_device.mm
    src/dm_uma_allocator.mm
    src/dm_tbdr_optimizer.mm
)

target_include_directories(dm_metal_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_metal_core PRIVATE ${DM_METAL_CORE_WARN_FLAGS})
target_link_libraries(dm_metal_core PUBLIC
    "-framework Metal"
    "-framework Foundation"
)

add_executable(dm_metal_probe
    tests/dm_metal_probe.mm
)
target_link_libraries(dm_metal_probe PRIVATE dm_metal_core)
target_compile_options(dm_metal_probe PRIVATE ${DM_METAL_CORE_WARN_FLAGS})

add_executable(dm_uma_bench
    tests/dm_uma_bench.mm
)
target_link_libraries(dm_uma_bench PRIVATE dm_metal_core)
target_compile_options(dm_uma_bench PRIVATE ${DM_METAL_CORE_WARN_FLAGS})

add_executable(dm_tbdr_bench
    tests/dm_tbdr_bench.mm
)
target_link_libraries(dm_tbdr_bench PRIVATE dm_metal_core)
target_compile_options(dm_tbdr_bench PRIVATE ${DM_METAL_CORE_WARN_FLAGS})

enable_testing()
add_test(NAME dm_metal_probe COMMAND dm_metal_probe)
set_tests_properties(dm_metal_probe PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "DM_CTEST_ALLOW_SKIP=1"
)

add_test(NAME dm_uma_bench COMMAND dm_uma_bench)
set_tests_properties(dm_uma_bench PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "DM_CTEST_ALLOW_SKIP=1"
)

add_test(NAME dm_tbdr_bench COMMAND dm_tbdr_bench)
set_tests_properties(dm_tbdr_bench PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "DM_CTEST_ALLOW_SKIP=1"
)
