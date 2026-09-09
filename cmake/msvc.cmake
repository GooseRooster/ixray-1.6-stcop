# Global options
# NOTE: do NOT pin /MD here — CMake's CMAKE_MSVC_RUNTIME_LIBRARY abstraction
# (CMP0091) owns the CRT selector and assembles it per configuration. Hand-
# pinning /MD in these strings mixes with the mapped flag and produces
# commands carrying BOTH /MD and -MDd (two CRT heaps → heap corruption).
set(CMAKE_CXX_FLAGS_DEBUG "")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /UMBCS /D_UNICODE /DUNICODE")

# Win32 Extensions
if (CMAKE_SIZEOF_VOID_P EQUAL 4)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} /LARGEADDRESSAWARE")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} /LARGEADDRESSAWARE")
    ADD_DEFINITIONS(/arch:SSE2)
endif()

# Apply definitions
add_compile_definitions(_WINDOWS)

# Enable gcc/clang style for MSVC
add_compile_options(/permissive- /fp:fast /wd4073 /wd4390 /wd4273 /sdl /wd4566 /wd4297 /wd4275 /wd4530)
# clang-cl: crc32.cpp uses the SSE4.2 CRC32 intrinsics, which MSVC compiles
# with its default baseline but clang gates behind an explicit feature flag
# (the Linux build does the same via -msse4.2 in cmake/clang.cmake).
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    add_compile_options(-msse4.2)
endif()
string(REGEX REPLACE "/EH[a-z]+" "" CMAKE_CXX_FLAGS ${CMAKE_CXX_FLAGS})
add_compile_options("$<$<CONFIG:DEBUG>:/Od>" "/Ob1")
add_compile_options("$<$<CONFIG:RELEASE>:/Ot>"  "$<$<CONFIG:RELEASE>:/Ob2>" "$<$<CONFIG:RELWITHDEBINFO>:/wd4577>")

add_compile_options($<$<CXX_COMPILER_ID:MSVC>:/MP>)
add_compile_options(/wd4595 /wd4996 /wd4005)
add_link_options("$<$<CONFIG:DEBUG>:/SAFESEH:NO>")
add_compile_options("$<$<CONFIG:RELEASE>:/wd4530>" "$<$<CONFIG:DEBUG>:/wd4251>" "$<$<CONFIG:RELWITHDEBINFO>:/wd4530>")

add_compile_options("$<$<CONFIG:RELEASE>:/GF>" "$<$<CONFIG:RELWITHDEBINFO>:/GF>")
add_compile_options("$<$<CONFIG:RELEASE>:/Oi>" "$<$<CONFIG:RELWITHDEBINFO>:/Oi>")
add_compile_options("$<$<CONFIG:RELEASE>:/Oy>" "$<$<CONFIG:RELWITHDEBINFO>:/Oy>")
add_compile_options("$<$<CONFIG:RELEASE>:/GT>" "$<$<CONFIG:RELWITHDEBINFO>:/GT>")
# /GL (whole program optimization) and /LTCG are MSVC-only; clang-cl
# (cross builds via cmake/msvc-cross.cmake) cannot consume them.
add_compile_options("$<$<AND:$<CONFIG:RELEASE>,$<CXX_COMPILER_ID:MSVC>>:/GL>" "$<$<AND:$<CONFIG:RELWITHDEBINFO>,$<CXX_COMPILER_ID:MSVC>>:/GL>")
add_compile_options("$<$<CONFIG:RELWITHDEBINFO>:/Ob2>")
add_compile_options("$<$<CONFIG:RELWITHDEBINFO>:/Ot>")
add_link_options("$<$<AND:$<CONFIG:RELEASE>,$<CXX_COMPILER_ID:MSVC>>:/LTCG:incremental>" "$<$<AND:$<CONFIG:RELWITHDEBINFO>,$<CXX_COMPILER_ID:MSVC>>:/LTCG:incremental>")
add_link_options("$<$<CONFIG:RELEASE>:/INCREMENTAL:NO>" "$<$<CONFIG:RELWITHDEBINFO>:/INCREMENTAL:NO>")

## Exceptions...
if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    string(REGEX REPLACE "/EH[a-z]+" "" CMAKE_CXX_FLAGS ${CMAKE_CXX_FLAGS})
    if (NOT IXRAY_LDEBUG)
        add_compile_options("$<$<CONFIG:DEBUG>:/EHsc>")
    endif()
else()
    # clang-cl (cross builds): hard-errors on try/throw when exceptions
    # are disabled; MSVC only emits (suppressed) C4530. Engine code such
    # as sdk/include/fast_dynamic_cast uses try/catch in Release, so
    # keep exception handling enabled for all configurations.
    add_compile_options(/EHsc)
endif()

## Edit and Continue mode
if (IXRAY_ASAN)
    add_compile_options("$<$<CONFIG:DEBUG>:/Zi>" "$<$<CONFIG:RELWITHDEBINFO>:/Zi>" "$<$<CONFIG:RELEASE>:/Zi>")
elseif (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    # /ZI (edit and continue) is MSVC-only; clang-cl uses plain /Zi.
    add_compile_options("$<$<CONFIG:DEBUG>:/ZI>" "$<$<CONFIG:RELWITHDEBINFO>:/Zi>" "$<$<CONFIG:RELEASE>:/Zi>")
else()
    add_compile_options("$<$<CONFIG:DEBUG>:/Zi>" "$<$<CONFIG:RELWITHDEBINFO>:/Zi>" "$<$<CONFIG:RELEASE>:/Zi>")
endif()

if(${CMAKE_GENERATOR_PLATFORM} MATCHES "arm64")
    set(IXR_ARM_ENABLE ON)
    add_compile_options(/Zc:preprocessor)
else()
    set(IXR_ARM_ENABLE OFF)
endif()

# Setup build patches
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# Hack for COPY
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_EX ${CMAKE_BINARY_DIR}/bin/$<CONFIG>/)

# Other
function(target_validate_pch target target_path)
	if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
		set_target_properties(${target} PROPERTIES DISABLE_PRECOMPILE_HEADERS ON)
		set_target_properties(${target} PROPERTIES COMPILE_FLAGS "/Yustdafx.h")
		set_source_files_properties(stdafx.cpp PROPERTIES COMPILE_FLAGS "/Ycstdafx.h")
		target_precompile_headers(${target} PRIVATE "stdafx.h")

		file(GLOB_RECURSE CORE_SOURCE_PCH_FILES "${target_path}/stdafx.*")
		file(GLOB_RECURSE CORE_SOURCE_ALL_C_FILES "${target_path}/*.c")

		set_source_files_properties(${CORE_SOURCE_ALL_C_FILES} PROPERTIES SKIP_PRECOMPILE_HEADERS ON)
		source_group("pch" FILES ${CORE_SOURCE_PCH_FILES})
	else()
		# clang-cl (cross builds via cmake/msvc-cross.cmake): the MSVC
		# /Yc + raw /Yu pipeline doesn't reliably produce/consume the
		# .pch here — build without precompiled headers instead.
		set_target_properties(${target} PROPERTIES DISABLE_PRECOMPILE_HEADERS ON)
	endif()
endfunction()

# Discord
option(IXRAY_DISCORD_RPC "Enable Discord activity" ON)

# Configure dependencies
set(RENDERDOC_API "${CMAKE_CURRENT_SOURCE_DIR}/src/3rd-party/renderdoc")