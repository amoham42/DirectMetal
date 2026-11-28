cmake_minimum_required(VERSION 3.20)
project(DirectMetal VERSION 1.0.0 LANGUAGES C CXX OBJCXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

enable_testing()

# Aggregate all 8 DirectMetal native C/Obj-C++ subsystems.
# Note: graphics/dm_metal_core is added prior to shaders/dm_shader_cache so
# dm_shader_cache links the top-level dm_metal_core target without duplicate subdirectory inclusion.
set(DM_NATIVE_SUBSYSTEMS
    runtime/dm_sync
    runtime/dm_prefix
    sandbox/dm_sandbox
    runtime/dm_host_io
    sandbox/dm_attestation
    graphics/dm_metal_core
    shaders/dm_shader_cache
    upscaling/dm_metalfx_bridge
)

foreach(_dm_sub IN LISTS DM_NATIVE_SUBSYSTEMS)
    get_filename_component(_dm_target "${_dm_sub}" NAME)
    if(NOT TARGET "${_dm_target}")
        add_subdirectory("${_dm_sub}")
    endif()
endforeach()

if(NOT TARGET dm_vk_compat_layer)
    add_subdirectory(graphics/dm_vk_compat)
endif()

# Keep C assert() checks active in C test harnesses even under -DCMAKE_BUILD_TYPE=Release (-DNDEBUG).
foreach(_dm_c_test_tgt IN ITEMS dm_sync_test dm_prefix_test dm_sandbox_test dm_vk_compat_test)
    if(TARGET "${_dm_c_test_tgt}")
        set_property(TARGET "${_dm_c_test_tgt}" APPEND PROPERTY COMPILE_OPTIONS -UNDEBUG)
    endif()
endforeach()

# Ensure ~/.ssh exists on clean runners so Seatbelt ~/.ssh EPERM probe is exercised rather than ENOENT.
if(DEFINED ENV{HOME} AND NOT "$ENV{HOME}" STREQUAL "")
    file(MAKE_DIRECTORY "$ENV{HOME}/.ssh")
endif()

function(dm_add_subdir_test_if_unregistered SUBDIR_REL TEST_NAME)
    set(_sub_cmake "${CMAKE_CURRENT_SOURCE_DIR}/${SUBDIR_REL}/CMakeLists.txt")
    if(EXISTS "${_sub_cmake}")
        file(READ "${_sub_cmake}" _sub_contents)
        if(NOT _sub_contents MATCHES "add_test[ \t\r\n]*\\(")
            add_test(NAME "${TEST_NAME}" COMMAND ${ARGN})
            set_tests_properties("${TEST_NAME}" PROPERTIES
                WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            )
        endif()
    endif()
endfunction()

if(TARGET dm_sync_test)
    dm_add_subdir_test_if_unregistered("runtime/dm_sync" dm_sync_test dm_sync_test)
endif()

if(TARGET dm_prefix_test)
    dm_add_subdir_test_if_unregistered("runtime/dm_prefix" dm_prefix_test dm_prefix_test)
endif()

if(TARGET dm_sandbox_test)
    dm_add_subdir_test_if_unregistered(
        "sandbox/dm_sandbox"
        dm_sandbox_test
        dm_sandbox_test "${CMAKE_CURRENT_SOURCE_DIR}/sandbox/profiles/directmetal_game.sb.tmpl"
    )
endif()

if(TARGET dm_vk_compat_test)
    add_test(
        NAME dm_vk_compat_test
        COMMAND dm_vk_compat_test $<TARGET_FILE:dm_vk_compat_layer>
    )
    set_tests_properties(dm_vk_compat_test PROPERTIES
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    )
endif()
