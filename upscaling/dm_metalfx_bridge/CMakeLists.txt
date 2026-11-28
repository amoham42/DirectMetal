cmake_minimum_required(VERSION 3.20)
project(dm_metalfx_bridge LANGUAGES C CXX OBJCXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(DM_METALFX_WARN_FLAGS
    $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>
    -Wall
    -Wextra
    -Werror
    -Wformat=2
    $<$<CONFIG:>:-O2>
)

add_library(dm_metalfx_bridge STATIC
    src/dm_metalfx_bridge.mm
    ../shims/ffx_fsr_shim.c
    ../shims/libxess_shim.c
)

target_include_directories(dm_metalfx_bridge PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shims
)

target_compile_options(dm_metalfx_bridge PRIVATE ${DM_METALFX_WARN_FLAGS})
target_link_libraries(dm_metalfx_bridge PUBLIC
    "-framework Metal"
    "-framework MetalFX"
    "-framework Foundation"
)

add_executable(dm_metalfx_bench
    tests/dm_metalfx_bench.mm
)
target_include_directories(dm_metalfx_bench PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance/common
)
target_link_libraries(dm_metalfx_bench PRIVATE dm_metalfx_bridge)
target_compile_options(dm_metalfx_bench PRIVATE ${DM_METALFX_WARN_FLAGS})

enable_testing()
add_test(
    NAME dm_metalfx_bench
    COMMAND dm_metalfx_bench --out-dir "${CMAKE_CURRENT_BINARY_DIR}/captures_metalfx"
)
set_tests_properties(dm_metalfx_bench PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "DM_CTEST_ALLOW_SKIP=1"
)
