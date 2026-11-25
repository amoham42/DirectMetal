cmake_minimum_required(VERSION 3.20)
project(dm_host_io LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(dm_host_io STATIC
    src/dm_host_io.mm
)

target_include_directories(dm_host_io PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_host_io PRIVATE -fobjc-arc -Wall -Wextra -O2)
target_link_libraries(dm_host_io PUBLIC
    "-framework CoreAudio"
    "-framework GameController"
    "-framework Foundation"
)

add_executable(dm_host_io_test
    tests/dm_host_io_test.mm
)

target_link_libraries(dm_host_io_test PRIVATE dm_host_io)
target_compile_options(dm_host_io_test PRIVATE -fobjc-arc -Wall -Wextra -O2)
