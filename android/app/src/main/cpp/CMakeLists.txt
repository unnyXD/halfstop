# Native build for the Android app.
#
# The render engine is the portable C++20 core + Vulkan compute backend that
# the upstream engine already uses on Windows/Linux. Nothing here is Android-specific
# inside engine/: we only tell its CMake where the toolchain's Vulkan headers
# and shader compiler live, switch off the desktop/host/test targets, and add
# a small C ABI shim that dart:ffi loads.
cmake_minimum_required(VERSION 3.22)
project(spektrafilm_mobile LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# android/app/src/main/cpp -> project root is five levels up.
set(SPK_THIRD_PARTY "${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/spektrafilm")
set(SPK_ENGINE "${SPK_THIRD_PARTY}/engine")

if(NOT EXISTS "${SPK_ENGINE}/CMakeLists.txt")
    message(FATAL_ERROR "engine sources missing at ${SPK_ENGINE}")
endif()

# --- Vulkan headers and shader compiler ---------------------------------
# The NDK ships both: <sysroot>/usr/include/vulkan and shader-tools/<host>/glslc.
# glslc is shaderc's front end; it takes the same -I/-o as glslangValidator but
# spells the target flags differently (see SPEKTRALAB_GLSLANG_FLAGS below,
# the option names follow the upstream engine's CMake and must not be renamed).
if(CMAKE_HOST_WIN32)
    set(SPK_HOST_TAG "windows-x86_64")
    set(SPK_GLSLC "${ANDROID_NDK}/shader-tools/${SPK_HOST_TAG}/glslc.exe")
elseif(CMAKE_HOST_APPLE)
    if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
        set(SPK_HOST_TAG "darwin-aarch64")
    else()
        set(SPK_HOST_TAG "darwin-x86_64")
    endif()
    set(SPK_GLSLC "${ANDROID_NDK}/shader-tools/${SPK_HOST_TAG}/glslc")
else()
    set(SPK_HOST_TAG "linux-x86_64")
    set(SPK_GLSLC "${ANDROID_NDK}/shader-tools/${SPK_HOST_TAG}/glslc")
endif()

if(NOT EXISTS "${SPK_GLSLC}")
    message(FATAL_ERROR "glslc not found at ${SPK_GLSLC}; NDK 26+ is required")
endif()
if(NOT EXISTS "${CMAKE_SYSROOT}/usr/include/vulkan/vulkan_core.h")
    message(FATAL_ERROR "Vulkan headers not found in the NDK sysroot (${CMAKE_SYSROOT})")
endif()

# --- engine configuration ----------------------------------------------
# Everything desktop-only is off. This leaves: spektralab_core,
# spektralab_pipeline, spk_volk, spektralab_engine (the Vulkan backend) and the
# SPIR-V/resource staging custom target.
set(SPEKTRALAB_VULKAN_HEADERS "${CMAKE_SYSROOT}/usr/include" CACHE PATH "" FORCE)
set(SPEKTRALAB_GLSLANG "${SPK_GLSLC}" CACHE FILEPATH "" FORCE)
set(SPEKTRALAB_GLSLANG_FLAGS "--target-env=vulkan1.0" CACHE STRING "" FORCE)

# Native RAW. LibRaw 0.22.2 is vendored by tool/fetch-libraw.ps1 next to the
# engine tree; the engine's LibRaw.cmake compiles its sources directly, so
# there is nothing to download at configure time and no Python anywhere.
set(SPK_LIBRAW_SOURCE "${SPK_THIRD_PARTY}/build/deps/LibRaw-0.22.2")
if(NOT EXISTS "${SPK_LIBRAW_SOURCE}/libraw/libraw.h")
    message(FATAL_ERROR
        "LibRaw 0.22.2 missing at ${SPK_LIBRAW_SOURCE}; run tool/fetch-libraw.ps1")
endif()
set(SPEKTRALAB_LIBRAW_SOURCE "${SPK_LIBRAW_SOURCE}" CACHE PATH "" FORCE)
set(SPEKTRALAB_BUILD_NATIVE_RAW ON CACHE BOOL "" FORCE)
set(SPEKTRALAB_LIBRAW_OPENMP ON CACHE BOOL "" FORCE)
set(SPEKTRALAB_BUILD_HOST OFF CACHE BOOL "" FORCE)
set(SPEKTRALAB_BUILD_DESKTOP OFF CACHE BOOL "" FORCE)
set(SPEKTRALAB_BUILD_TEST_DLL OFF CACHE BOOL "" FORCE)
set(SPEKTRALAB_REQUIRE_VULKAN ON CACHE BOOL "" FORCE)
set(SPEKTRALAB_STATIC_RUNTIME OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

add_subdirectory("${SPK_ENGINE}" "${CMAKE_CURRENT_BINARY_DIR}/engine")

# --- the FFI shim -------------------------------------------------------
# libspektrafilm.so: the engine's C ABI plus a couple of probe entry points.
# dart:ffi opens it with DynamicLibrary.open("libspektrafilm.so").
add_library(spektrafilm SHARED spk_mobile.cpp)
target_compile_features(spektrafilm PRIVATE cxx_std_20)
target_include_directories(spektrafilm PRIVATE
    "${SPK_ENGINE}/include"
    "${SPK_ENGINE}/src")
target_link_libraries(spektrafilm PRIVATE
    spektralab_engine
    spk_image_io
    # Directly, for the embedded JPEG preview the home grid shows as a tile:
    # `spk_image_io` links LibRaw privately, so its headers are not visible
    # here, and `unpack_thumb` is a header read, not a decode.
    spk_libraw
    spk_volk
    android
    log)
set_target_properties(spektrafilm PROPERTIES
    OUTPUT_NAME spektrafilm
    CXX_VISIBILITY_PRESET default
    VISIBILITY_INLINES_HIDDEN OFF)
