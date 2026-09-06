file(GLOB DXERR_SRC CONFIGURE_DEPENDS
	"*.cpp"
	"*.h"
)

add_library(dxerr STATIC ${DXERR_SRC})
target_compile_options(dxerr PRIVATE "/wd4005")
if (NOT CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    # clang-cl: MSVC tolerates narrowing HRESULT case labels in the
    # vendored Microsoft DXGetError*.inl tables.
    target_compile_options(dxerr PRIVATE "-Wno-c++11-narrowing")
endif()
target_include_directories(dxerr PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})