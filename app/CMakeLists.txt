# crater (executable)
#
# Thin shell that wires the QML UI to crater-core engine services.

qt_add_executable(crater
    src/main.cpp
    src/FileDialogService.cpp
    src/FileDialogService.h
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

        # ── Theme-rendering components (shared by ProjectionWindow,
        #    ThemesTab tiles, and the theme editor canvas) ─────────────
        qml/components/NodeRenderer.qml
        qml/components/MediaBackgroundLoader.qml
        qml/components/ThemePreview.qml
        qml/components/ColorPicker.qml
        qml/components/ColorPickerPopover.qml
        qml/components/ColorSwatchInput.qml
        qml/components/ConfirmationOverlay.qml

        # ── Theme editor workspace + editor child components ─────────
        qml/workspaces/ThemeEditorWorkspace.qml
        qml/workspaces/editor/EditorHeader.qml
        qml/workspaces/editor/EditorToolbar.qml
        qml/workspaces/editor/EditorFooter.qml
        qml/workspaces/editor/EditorCanvas.qml
        qml/workspaces/editor/NodeDelegate.qml
        qml/workspaces/editor/ResizeHandle.qml
        qml/workspaces/editor/LayersPanel.qml
        qml/workspaces/editor/PropertiesPanel.qml
        qml/workspaces/editor/AccordionSection.qml
        qml/workspaces/editor/TransformProperties.qml
        qml/workspaces/editor/TextPropertiesContent.qml
        qml/workspaces/editor/ContainerPropertiesContent.qml
        qml/workspaces/editor/inputs/NumericInput.qml
        qml/workspaces/editor/inputs/SimpleSlider.qml
        qml/workspaces/editor/inputs/SegmentedControl.qml

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

# Bundle the Lucide icon font and Funnel Sans body font as Qt resources
# (qrc:/fonts/*). main.cpp registers them at startup via QFontDatabase.
qt_add_resources(crater "appfonts"
    PREFIX "/fonts"
    BASE   "${CMAKE_CURRENT_SOURCE_DIR}/resources/fonts"
    FILES
        resources/fonts/lucide.ttf
        resources/fonts/FunnelSans-VariableFont_wght.ttf
)

target_link_libraries(crater
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        # Qt6::Widgets is required for QFileDialog (the native file picker
        # used by FileDialogService). It does not pull QtQuick.Dialogs into
        # the QML runtime — that's a separate, forbidden module.
        Qt6::Widgets
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
