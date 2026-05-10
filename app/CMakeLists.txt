# crater (executable)
#
# Thin shell that wires the QML UI to crater-core engine services.

qt_add_executable(crater
    src/main.cpp
)

qt_add_qml_module(crater
    URI Crater
    VERSION 1.0
    QML_FILES
        qml/Main.qml
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

# Installation rules so `cmake --install` produces a redistributable bundle.
install(TARGETS crater
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION bin
)
