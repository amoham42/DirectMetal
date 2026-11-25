cmake_minimum_required(VERSION 3.20)
project(dm_prefix LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(dm_prefix STATIC
    src/dm_prefix.c
)

target_include_directories(dm_prefix PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_prefix PRIVATE -Wall -Wextra -O2)

add_executable(dm_prefix_test
    tests/dm_prefix_test.c
)

target_link_libraries(dm_prefix_test PRIVATE dm_prefix)
target_compile_options(dm_prefix_test PRIVATE -Wall -Wextra -O2)
