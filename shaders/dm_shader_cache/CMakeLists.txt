cmake_minimum_required(VERSION 3.20)
project(dm_shader_cache LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(DM_SHADER_CACHE_WARN_FLAGS
    -fobjc-arc
    -Wall
    -Wextra
    -Werror
    -Wformat=2
    $<$<CONFIG:>:-O2>
)

if(NOT TARGET dm_metal_core)
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../graphics/dm_metal_core dm_metal_core_build)
endif()

add_library(dm_shader_cache STATIC
    src/dm_shader_cache.mm
)

target_include_directories(dm_shader_cache PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../graphics/dm_metal_core/include
)

target_compile_options(dm_shader_cache PRIVATE ${DM_SHADER_CACHE_WARN_FLAGS})
target_link_libraries(dm_shader_cache PUBLIC
    dm_metal_core
    "-framework Metal"
    "-framework Foundation"
)

add_executable(dm_shader_cache_test
    tests/dm_shader_cache_test.mm
)
target_link_libraries(dm_shader_cache_test PRIVATE dm_shader_cache)
target_compile_options(dm_shader_cache_test PRIVATE ${DM_SHADER_CACHE_WARN_FLAGS})

enable_testing()
add_test(NAME dm_shader_cache_test COMMAND dm_shader_cache_test)
set_tests_properties(dm_shader_cache_test PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "DM_CTEST_ALLOW_SKIP=1"
)
