cmake_minimum_required(VERSION 3.20)
project(dm_vk_compat LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(DM_VK_COMPAT_WARN_FLAGS
    -Wall
    -Wextra
    -Werror
    -Wformat=2
    $<$<CONFIG:>:-O2>
)

add_library(dm_vk_compat_layer SHARED
    dm_vk_compat_layer.c
)

set_target_properties(dm_vk_compat_layer PROPERTIES
    OUTPUT_NAME "dm_vk_compat_layer"
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

target_compile_options(dm_vk_compat_layer PRIVATE
    ${DM_VK_COMPAT_WARN_FLAGS}
    -fvisibility=hidden
)

add_executable(dm_vk_compat_test
    tests/dm_vk_compat_test.c
)

add_dependencies(dm_vk_compat_test dm_vk_compat_layer)

target_link_libraries(dm_vk_compat_test PRIVATE
    ${CMAKE_DL_LIBS}
)

target_compile_options(dm_vk_compat_test PRIVATE
    ${DM_VK_COMPAT_WARN_FLAGS}
    -UNDEBUG
)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    enable_testing()
    add_test(
        NAME dm_vk_compat_test
        COMMAND dm_vk_compat_test $<TARGET_FILE:dm_vk_compat_layer>
    )
endif()
