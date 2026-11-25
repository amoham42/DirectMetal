cmake_minimum_required(VERSION 3.20)
project(dm_d3d11_conformance LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

add_executable(dm_d3d11_conformance
    dm_d3d11_conformance.cpp
)

target_include_directories(dm_d3d11_conformance PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../common
)

target_link_libraries(dm_d3d11_conformance PRIVATE
    d3d11
    dxgi
    d3dcompiler
)

if(MSVC)
    target_compile_options(dm_d3d11_conformance PRIVATE /W3 /O2 /EHsc)
endif()
