cmake_minimum_required(VERSION 3.20)
project(dm_d3d12_conformance LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

find_program(DXC_EXECUTABLE dxc)
set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(EXTRA_DEFS "")
if(DXC_EXECUTABLE AND WIN32)
    message(STATUS "DirectMetal: Found dxc at ${DXC_EXECUTABLE}; compiling SM 6.0 DXIL compute shader")
    set(DXIL_HEADER "${GENERATED_DIR}/d3d12_dxil_compute.h")
    add_custom_command(
        OUTPUT "${DXIL_HEADER}"
        COMMAND "${DXC_EXECUTABLE}" -T cs_6_0 -E CSMain -Vn kComputeDXIL -Fh "${DXIL_HEADER}"
                "${CMAKE_CURRENT_SOURCE_DIR}/shaders/d3d12_compute_uav.hlsl"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/shaders/d3d12_compute_uav.hlsl"
        COMMENT "Compiling SM 6.0 DXIL compute shader via dxc"
    )
    add_custom_target(dm_d3d12_dxil_gen DEPENDS "${DXIL_HEADER}")
    set(EXTRA_DEFS "DM_HAS_SIGNED_DXIL=1")
endif()

add_executable(dm_d3d12_conformance
    dm_d3d12_conformance.cpp
)

if(TARGET dm_d3d12_dxil_gen)
    add_dependencies(dm_d3d12_conformance dm_d3d12_dxil_gen)
endif()

target_include_directories(dm_d3d12_conformance PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../common
    ${GENERATED_DIR}
)

if(EXTRA_DEFS)
    target_compile_definitions(dm_d3d12_conformance PRIVATE ${EXTRA_DEFS})
endif()

target_link_libraries(dm_d3d12_conformance PRIVATE
    d3d12
    dxgi
    d3dcompiler
)

if(MSVC)
    target_compile_options(dm_d3d12_conformance PRIVATE /W3 /O2 /EHsc)
endif()
