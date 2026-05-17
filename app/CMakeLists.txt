# crater (executable)
#
# Thin shell that wires the QML UI to crater-core engine services.

qt_add_executable(crater
    src/main.cpp
    src/FileDialogService.cpp
    src/FileDialogService.h
    src/VideoThumbnailer.cpp
    src/VideoThumbnailer.h
    src/MediaPlaybackService.cpp
    src/MediaPlaybackService.h
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
        qml/controls/MenuRow.qml
        qml/controls/RightClickArea.qml
        qml/controls/ToggleSwitch.qml
        qml/controls/SelectChip.qml
        qml/controls/Combobox.qml

        # ── Theme-rendering components (shared by ProjectionWindow,
        #    ThemesTab tiles, and the theme editor canvas) ─────────────
        qml/components/NodeRenderer.qml
        qml/components/MediaBackgroundLoader.qml
        qml/components/MediaMonitor.qml
        qml/components/ThemedMonitor.qml
        qml/components/ThemePreview.qml
        qml/components/LogoView.qml
        qml/components/LyricSectionEditor.qml
        qml/components/ColorPicker.qml
        qml/components/ColorPickerPopover.qml
        qml/components/ColorSwatchInput.qml
        qml/components/MediaPickerPopover.qml
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
        # Qt6::Multimedia provides MediaPlayer + VideoOutput, used by
        # MediaBackgroundLoader.qml for video backgrounds inside container
        # theme nodes. Linking it also triggers Qt's QML-import deployer
        # to copy the QtMultimedia QML module + its native DLLs.
        Qt6::Multimedia
        Crater::Core
)

set_target_properties(crater PROPERTIES
    WIN32_EXECUTABLE ON
    MACOSX_BUNDLE  ON
    # Pin the runtime output to <build>/ so the exe is at a predictable path
    # regardless of generator (Ninja single-config drops it under the source
    # subdir by default; MSBuild adds a per-config subdir). Keeps `cmake
    # --build && .\build\crater.exe` working across both.
    RUNTIME_OUTPUT_DIRECTORY              "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE      "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG        "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_BINARY_DIR}"
)

# Qt's auto-deploy for the build tree copies most Qt-Quick modules but
# does NOT follow recent additions to target_link_libraries (Qt6::Widgets)
# or QML-only imports outside its scanned set (QtMultimedia). Without
# these explicit copies the build-tree exe fails to load silently — the
# Win32 GUI subsystem suppresses the loader error. We keep these narrow
# rather than running full windeployqt because the existing auto-deploy
# already handles everything else.
if(WIN32)
    # Qt6Widgets.dll — pulled in via QFileDialog in FileDialogService.
    add_custom_command(TARGET crater POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:Qt6::Widgets>"
            "$<TARGET_FILE_DIR:crater>"
        COMMENT "Copying Qt6Widgets.dll next to crater.exe"
        VERBATIM)

    # Qt6Multimedia.dll — used by MediaBackgroundLoader.qml (video bgs).
    add_custom_command(TARGET crater POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:Qt6::Multimedia>"
            "$<TARGET_FILE_DIR:crater>"
        COMMENT "Copying Qt6Multimedia.dll next to crater.exe"
        VERBATIM)

    # Qt6Network.dll — Qt6::Multimedia has a runtime dep on Network on
    # Windows (HTTP streaming surfaces). Already deployed by other modules
    # in our case, but the copy_if_different makes the intent explicit
    # and is a no-op when up to date.
    add_custom_command(TARGET crater POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:Qt6::Network>"
            "$<TARGET_FILE_DIR:crater>"
        COMMENT "Copying Qt6Network.dll next to crater.exe"
        VERBATIM)

    # QtMultimedia QML module — Qt's qmlimportscanner doesn't see the
    # `import QtMultimedia` from our QML, so we copy the QML module to the
    # standard <exe>/qml/QtMultimedia/ location (matches windeployqt's
    # layout + Qt's default QML import-path lookup).
    add_custom_command(TARGET crater POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "$<TARGET_FILE_DIR:Qt6::Core>/../qml/QtMultimedia"
            "$<TARGET_FILE_DIR:crater>/qml/QtMultimedia"
        COMMENT "Copying QtMultimedia QML module to <exe>/qml/QtMultimedia"
        VERBATIM)
endif()

install(TARGETS crater
    BUNDLE  DESTINATION .
    RUNTIME DESTINATION bin
)
