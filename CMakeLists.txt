cmake_minimum_required(VERSION 3.21)

project(Crater
    VERSION 0.6.0
    DESCRIPTION "Professional Scripture Projection Software"
    HOMEPAGE_URL "https://crater.voyagerlabs.tech"
    LANGUAGES C CXX  # C needed for sqlite3.c amalgamation in crater-core
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
find_package(Qt6 6.5 REQUIRED COMPONENTS
    Core
    Concurrent      # QtConcurrent::run for worker-thread import + FTS rebuild
    Gui
    GuiPrivate      # exposes <rhi/qrhi.h> for the headless NDI renderer
    Qml
    Quick
    QuickControls2
    QuickEffects   # MultiEffect — drop shadow / blur via the QtQuick.Effects QML module
    Sql
    Multimedia
    Pdf             # PDF rasterization via pdfium — used by MediaService + PdfPageImageProvider
    Test            # Headless Qt Test runner — required when CRATER_BUILD_TESTS=ON
    WebSockets
    Widgets         # QApplication + QFileDialog (used by FileDialogService for native pickers)
)

qt_standard_project_setup(REQUIRES 6.5)

add_subdirectory(core)
add_subdirectory(app)
