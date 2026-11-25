cmake_minimum_required(VERSION 3.20)
project(dm_sync LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(dm_sync STATIC
    src/dm_sync.c
)

target_include_directories(dm_sync PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_sync PRIVATE -Wall -Wextra -O2)

add_executable(dm_sync_test
    tests/dm_sync_test.c
)

target_link_libraries(dm_sync_test PRIVATE dm_sync)
target_compile_options(dm_sync_test PRIVATE -Wall -Wextra -O2)
