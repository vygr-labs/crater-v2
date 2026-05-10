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

# Target: Qt 6.11+. We track the latest Qt to stay on the newest QML
# compiler (qmlsc) and RHI improvements — meaningful perf gains on the
# weak hardware Crater targets (Intel HD 4000 / 4 GB RAM).
find_package(Qt6 6.11 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    Sql
    Multimedia
    WebSockets
)

qt_standard_project_setup(REQUIRES 6.11)

add_subdirectory(core)
add_subdirectory(app)
