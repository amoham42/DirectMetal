cmake_minimum_required(VERSION 3.20)
project(dm_metalfx_bridge LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(dm_metalfx_bridge STATIC
    src/dm_metalfx_bridge.mm
    ../shims/ffx_fsr_shim.c
    ../shims/libxess_shim.c
)

target_include_directories(dm_metalfx_bridge PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shims
)

target_compile_options(dm_metalfx_bridge PRIVATE -fobjc-arc -Wall -Wextra -O2)
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
target_compile_options(dm_metalfx_bench PRIVATE -fobjc-arc -Wall -Wextra -O2)
