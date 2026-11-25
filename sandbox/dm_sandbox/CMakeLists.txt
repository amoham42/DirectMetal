cmake_minimum_required(VERSION 3.20)
project(dm_sandbox LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(dm_sandbox STATIC
    src/dm_sandbox.c
)

target_include_directories(dm_sandbox PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_sandbox PRIVATE -Wall -Wextra -Werror -O2)

add_executable(dm_sandbox_test
    tests/dm_sandbox_test.c
)
target_link_libraries(dm_sandbox_test PRIVATE dm_sandbox)
target_compile_options(dm_sandbox_test PRIVATE -Wall -Wextra -Werror -O2)
