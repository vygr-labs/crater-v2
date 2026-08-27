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

# White-box access to crater-core's PRIVATE headers: the test drives the zip
# wrapper directly via #include "bundle/Zip.h". crater-core declares src/ as a
# PRIVATE include dir so it doesn't leak to normal consumers, which means it
# isn't on this target's include path by default — restate it for the test.
target_include_directories(test_theme_bundle PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME theme_bundle COMMAND test_theme_bundle)
# -- Version ordering -- docs/auto-update.md ----------------------------
# Pure string comparison behind the updater's "is this an upgrade?"
# decision. No network, no database, no Gui: crater::compareVersions is
# Core-only, so this is the cheapest test in the suite and among the most
# worth having, because its failure mode is a silent no-op.
qt_add_executable(test_version_compare
    test_version_compare.cpp
)

target_link_libraries(test_version_compare PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

add_test(NAME version_compare COMMAND test_version_compare)

# -- SHA256SUMS parsing -- docs/auto-update.md --------------------------
# The lookup that decides whether a downloaded installer may run. Pure text
# in, hex out, so it tests headlessly; and it MUST be tested here, because
# the file it parses is written by the release workflow and read months
# later by an installed copy, with no closer place to catch a mistake.
qt_add_executable(test_checksums
    test_checksums.cpp
)

target_link_libraries(test_checksums PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

add_test(NAME checksums COMMAND test_checksums)

# -- Theme layouts (tokens v3) -- crater/ThemeTokens.h ------------------
# Pure token-shape logic behind presentation layouts: which design a slide
# renders with, and what happens when the theme underneath it changes. No
# database and no Gui, so it is Core-only and among the cheapest tests
# here; and it covers the one path with a silent failure mode, where a deck
# authored under one theme is projected under another that never heard of
# the layout it asks for.
qt_add_executable(test_theme_layouts
    test_theme_layouts.cpp
)

target_link_libraries(test_theme_layouts PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

add_test(NAME theme_layouts COMMAND test_theme_layouts)
