# crater-core tests
#
# Headless Qt Test binaries that exercise crater-core in isolation, per
# ARCHITECTURE.md §1: the engine should be testable without the QML/UI
# layer. Add new test binaries here as the engine grows.

qt_add_executable(test_lyrics_dsl
    test_lyrics_dsl.cpp
)

target_link_libraries(test_lyrics_dsl PRIVATE
    Qt6::Core
    # Qt6::Gui is required because LyricsDSL.cpp's htmlToDsl uses
    # QTextDocument / QTextBlock / QTextCharFormat. crater-core links
    # Qt6::Gui as PRIVATE so it doesn't propagate — we restate it here.
    Qt6::Gui
    Qt6::Test
    crater-core
)

# Register with CTest so `ctest` runs the suite from any build dir.
add_test(NAME lyrics_dsl COMMAND test_lyrics_dsl)

# ── Theme bundle (.craterheme v2) — ARCHITECTURE.md §10 ────────────────
# Covers both the zip wrapper in isolation and the full ThemeService
# export -> reset -> import round trip. Needs Qt6::Gui (QFontDatabase /
# QGuiApplication) and the test-mode AppDataLocation flag set in main().
qt_add_executable(test_theme_bundle
    test_theme_bundle.cpp
)

target_link_libraries(test_theme_bundle PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

add_test(NAME theme_bundle COMMAND test_theme_bundle)
