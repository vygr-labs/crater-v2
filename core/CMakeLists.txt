# crater-core
#
# Headless engine library: SQLite-backed Bible/song/theme operations,
# NDI sender, and (eventually) the WebSocket remote server.
# UI code (qt/app) consumes this through Q_OBJECT models and services.

add_library(crater-core STATIC
    src/Version.cpp
    src/BibleService.cpp
)

target_include_directories(crater-core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(crater-core
    PUBLIC
        Qt6::Core
        Qt6::Sql
)

target_compile_definitions(crater-core
    PUBLIC
        CRATER_VERSION_STRING="${PROJECT_VERSION}"
)

add_library(Crater::Core ALIAS crater-core)
