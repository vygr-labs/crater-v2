# crater (executable)
#
# Thin shell that wires the QML UI to crater-core engine services.

qt_add_executable(crater
    src/main.cpp
)

# Mark singletons before qt_add_qml_module so the metadata is honored.
# AppState joins Theme, LucideIcons, and Workspaces as a singleton — it
# holds all transient UI state and is bound from every panel/dialog.
set_source_files_properties(
    qml/Theme.qml
    qml/LucideIcons.qml
    qml/Workspaces.qml
    qml/AppState.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE
)

qt_add_qml_module(crater
    URI Crater
    VERSION 1.0
    QML_FILES
        # ── Entry point + global state ────────────────────────────────
        qml/Main.qml
        qml/AppState.qml
        qml/Theme.qml
        qml/LucideIcons.qml
        qml/Workspaces.qml
        qml/ModalLayer.qml
        qml/ProjectionWindow.qml

        # ── Reusable control atoms ────────────────────────────────────
        qml/controls/AppIcon.qml
        qml/controls/IconButton.qml
        qml/controls/Badge.qml
        qml/controls/EmptyState.qml
        qml/controls/Monitor.qml
        qml/controls/PaneHeader.qml
        qml/controls/GhostButton.qml
        qml/controls/PrimaryButton.qml
        qml/controls/PillButton.qml
        qml/controls/SearchBar.qml
        qml/controls/TabSearchBar.qml
        qml/controls/PopoverMenu.qml
        qml/controls/ContextMenu.qml
        qml/controls/ToggleSwitch.qml
        qml/controls/SelectChip.qml

        # ── Major UI panels ───────────────────────────────────────────
        qml/panels/TopBar.qml
        qml/panels/SchedulePanel.qml
        qml/panels/PreviewPanel.qml
        qml/panels/LivePanel.qml
        qml/panels/LibraryTabBar.qml
        qml/panels/LibrarySidebar.qml
        qml/panels/LibraryContent.qml
        qml/panels/FooterBar.qml
        qml/panels/LibraryRow.qml
        qml/panels/ScheduleRow.qml

        # ── Library tab content (lazy-loaded) ─────────────────────────
        qml/tabs/SongsTab.qml
        qml/tabs/ScriptureTab.qml
        qml/tabs/StrongsTab.qml
        qml/tabs/MediaTab.qml
        qml/tabs/ThemesTab.qml

        # ── Modal dialogs ─────────────────────────────────────────────
        qml/dialogs/ModalShell.qml
        qml/dialogs/SettingsDialog.qml
        qml/dialogs/SongEditorDialog.qml
        qml/dialogs/ThemeEditorDialog.qml
        qml/dialogs/NamingDialog.qml
        qml/dialogs/ConfirmDialog.qml
        qml/dialogs/ImportDialog.qml
        qml/dialogs/ScheduleDropdownPopover.qml

        # ── Settings sections ─────────────────────────────────────────
        qml/dialogs/settings/AppearanceSection.qml
        qml/dialogs/settings/ProjectionSection.qml
        qml/dialogs/settings/ScriptureSection.qml
        qml/dialogs/settings/SongSection.qml
        qml/dialogs/settings/RemoteControlSection.qml
        qml/dialogs/settings/NdiSection.qml
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
