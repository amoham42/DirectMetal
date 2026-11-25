cmake_minimum_required(VERSION 3.20)
project(dm_metal_core LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(dm_metal_core STATIC
    src/dm_metal_device.mm
)

target_include_directories(dm_metal_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_metal_core PRIVATE -fobjc-arc -Wall -Wextra -O2)
target_link_libraries(dm_metal_core PUBLIC
    "-framework Metal"
    "-framework Foundation"
)

add_executable(dm_metal_probe
    tests/dm_metal_probe.mm
)

target_link_libraries(dm_metal_probe PRIVATE dm_metal_core)
target_compile_options(dm_metal_probe PRIVATE -fobjc-arc -Wall -Wextra -O2)
