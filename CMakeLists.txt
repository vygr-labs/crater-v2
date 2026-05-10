cmake_minimum_required(VERSION 3.21)

project(Crater
    VERSION 0.6.0
    DESCRIPTION "Professional Scripture Projection Software"
    HOMEPAGE_URL "https://crater.voyagerlabs.tech"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Target: Qt 6.5+ (LTS line; ships with the QML toolchain we rely on).
find_package(Qt6 6.5 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    Sql
    Multimedia
    WebSockets
)

qt_standard_project_setup(REQUIRES 6.5)

add_subdirectory(core)
add_subdirectory(app)
