# crater (executable)
#
# Thin shell that wires the QML UI to crater-core engine services.

qt_add_executable(crater
    src/main.cpp
)

# Mark singletons before qt_add_qml_module so the metadata is honored.
set_source_files_properties(qml/Theme.qml qml/LucideIcons.qml PROPERTIES
    QT_QML_SINGLETON_TYPE TRUE
)

qt_add_qml_module(crater
    URI Crater
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/LucideIcons.qml
        qml/AppIcon.qml
        qml/PaneHeader.qml
        qml/Badge.qml
        qml/IconButton.qml
        qml/Monitor.qml
        qml/LibraryRow.qml
        qml/ScheduleRow.qml
        qml/EmptyState.qml
)

# Bundle the Lucide icon font as a Qt resource (qrc:/fonts/lucide.ttf).
qt_add_resources(crater "appfonts"
    PREFIX "/fonts"
    BASE   "${CMAKE_CURRENT_SOURCE_DIR}/resources/fonts"
    FILES
        resources/fonts/lucide.ttf
)

target_link_libraries(crater
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        Crater::Core
)

set_target_properties(crater PROPERTIES
    WIN32_EXECUTABLE ON
    MACOSX_BUNDLE  ON
)

install(TARGETS crater
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION bin
)
