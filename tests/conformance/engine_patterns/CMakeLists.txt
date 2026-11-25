cmake_minimum_required(VERSION 3.20)
project(dm_engine_conformance LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

find_program(DXC_EXECUTABLE dxc
    HINTS
        "C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64"
        "C:/Program Files (x86)/Windows Kits/10/bin/10.0.22621.0/x64"
)
if(NOT DXC_EXECUTABLE)
    message(FATAL_ERROR "DirectMetal: dxc not found. Engine conformance requires SM 6.0 DXIL compilation.")
endif()
message(STATUS "DirectMetal: Found dxc at ${DXC_EXECUTABLE}")

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(SHADER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/shaders")
set(GENERATED_HEADERS "")

function(add_sm6_shader HLSL_FILE PROFILE ENTRY VAR_NAME HEADER_NAME)
    set(IN_PATH "${SHADER_DIR}/${HLSL_FILE}")
    set(OUT_PATH "${GENERATED_DIR}/${HEADER_NAME}")
    add_custom_command(
        OUTPUT "${OUT_PATH}"
        COMMAND "${DXC_EXECUTABLE}" -T ${PROFILE} -E ${ENTRY} -O3 -Vn ${VAR_NAME} -Fh "${OUT_PATH}" "${IN_PATH}"
        DEPENDS "${IN_PATH}"
        COMMENT "Compiling ${HLSL_FILE} (${ENTRY} : ${PROFILE}) -> ${HEADER_NAME}"
    )
    list(APPEND GENERATED_HEADERS "${OUT_PATH}")
    set(GENERATED_HEADERS "${GENERATED_HEADERS}" PARENT_SCOPE)
endfunction()

add_sm6_shader("eng_01_gbuffer.hlsl"       "vs_6_0" "VSMain"        "kEng01GBufferVS"     "eng_01_gbuffer_vs.h")
add_sm6_shader("eng_01_gbuffer.hlsl"       "ps_6_0" "PSMain"        "kEng01GBufferPS"     "eng_01_gbuffer_ps.h")
add_sm6_shader("eng_01_deferred_pbr.hlsl"  "vs_6_0" "VSMain"        "kEng01DeferredVS"    "eng_01_deferred_vs.h")
add_sm6_shader("eng_01_deferred_pbr.hlsl"  "ps_6_0" "PSMain"        "kEng01DeferredPS"    "eng_01_deferred_ps.h")
add_sm6_shader("eng_02_shadow.hlsl"        "vs_6_0" "VSDepth"       "kEng02ShadowVSDepth" "eng_02_shadow_vs_depth.h")
add_sm6_shader("eng_02_shadow.hlsl"        "vs_6_0" "VSMain"        "kEng02ShadowVSMain"  "eng_02_shadow_vs_main.h")
add_sm6_shader("eng_02_shadow.hlsl"        "ps_6_0" "PSMain"        "kEng02ShadowPSMain"  "eng_02_shadow_ps_main.h")
add_sm6_shader("eng_03_cull.hlsl"          "cs_6_0" "CSMain"        "kEng03CullCS"        "eng_03_cull_cs.h")
add_sm6_shader("eng_03_draw.hlsl"          "vs_6_0" "VSMain"        "kEng03DrawVS"        "eng_03_draw_vs.h")
add_sm6_shader("eng_03_draw.hlsl"          "ps_6_0" "PSMain"        "kEng03DrawPS"        "eng_03_draw_ps.h")
add_sm6_shader("eng_04_hdr_bloom.hlsl"     "vs_6_0" "VSHDR"         "kEng04HdrVS"         "eng_04_hdr_vs.h")
add_sm6_shader("eng_04_hdr_bloom.hlsl"     "ps_6_0" "PSHDR"         "kEng04HdrPS"         "eng_04_hdr_ps.h")
add_sm6_shader("eng_04_hdr_bloom.hlsl"     "cs_6_0" "CSBrightBlurH" "kEng04BlurHCS"       "eng_04_blur_h_cs.h")
add_sm6_shader("eng_04_hdr_bloom.hlsl"     "cs_6_0" "CSBlurV"       "kEng04BlurVCS"       "eng_04_blur_v_cs.h")
add_sm6_shader("eng_04_hdr_bloom.hlsl"     "vs_6_0" "VSTonemap"     "kEng04TonemapVS"     "eng_04_tonemap_vs.h")
add_sm6_shader("eng_04_hdr_bloom.hlsl"     "ps_6_0" "PSTonemap"     "kEng04TonemapPS"     "eng_04_tonemap_ps.h")
add_sm6_shader("eng_05_wave_ops.hlsl"      "cs_6_0" "CSMain"        "kEng05WaveOpsCS"     "eng_05_wave_ops_cs.h")
add_sm6_shader("eng_06_bindless.hlsl"      "vs_6_0" "VSMain"        "kEng06BindlessVS"    "eng_06_bindless_vs.h")
add_sm6_shader("eng_06_bindless.hlsl"      "ps_6_0" "PSMain"        "kEng06BindlessPS"    "eng_06_bindless_ps.h")

add_custom_target(dm_engine_dxil_gen DEPENDS ${GENERATED_HEADERS})

add_executable(dm_engine_conformance
    dm_engine_conformance.cpp
)
add_dependencies(dm_engine_conformance dm_engine_dxil_gen)

target_include_directories(dm_engine_conformance PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../common
    ${GENERATED_DIR}
)

target_link_libraries(dm_engine_conformance PRIVATE
    d3d12
    dxgi
    d3dcompiler
)

if(MSVC)
    target_compile_options(dm_engine_conformance PRIVATE /W3 /O2 /EHsc)
endif()
