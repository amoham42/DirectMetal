cmake_minimum_required(VERSION 3.20)
project(dm_host_io LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(DM_HOST_IO_WARN_FLAGS
    -fobjc-arc
    -Wall
    -Wextra
    -Werror
    -Wformat=2
    $<$<CONFIG:>:-O2>
)

add_library(dm_host_io STATIC
    src/dm_host_io.mm
)

target_include_directories(dm_host_io PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(dm_host_io PRIVATE ${DM_HOST_IO_WARN_FLAGS})
target_link_libraries(dm_host_io PUBLIC
    "-framework CoreAudio"
    "-framework GameController"
    "-framework Foundation"
)

add_executable(dm_host_io_test
    tests/dm_host_io_test.mm
)

target_link_libraries(dm_host_io_test PRIVATE dm_host_io)
target_compile_options(dm_host_io_test PRIVATE ${DM_HOST_IO_WARN_FLAGS})

enable_testing()
add_test(NAME dm_host_io_test COMMAND dm_host_io_test)
