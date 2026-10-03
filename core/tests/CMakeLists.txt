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

# -- Built-in scripture themes -- V012 --------------------------------------
# V012 makes Plum & Rose the scripture default on fresh installs only. An
# upgrade that switched it would change what a congregation sees without
# anyone choosing it, so both paths run through the real Migrator here.
qt_add_executable(test_scripture_themes
    test_scripture_themes.cpp
)

target_link_libraries(test_scripture_themes PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

# Rewinds user_version through the private db/ wrappers.
target_include_directories(test_scripture_themes PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME scripture_themes COMMAND test_scripture_themes)
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

# -- Theme editor working copy -- crater/WorkingTheme.h -----------------
# The editor's in-memory theme once it grew from one flat node list to a set
# of named layouts. Core-only (QObject + QVariant, no database, no Gui), and
# aimed squarely at the quiet failures: an edit landing in the wrong design,
# a save dropping the designs the author was not looking at, and an undo
# bouncing them out of the design they were working on.
qt_add_executable(test_working_theme
    test_working_theme.cpp
)

target_link_libraries(test_working_theme PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

add_test(NAME working_theme COMMAND test_working_theme)

# -- Design with AI -- crater/ThemePrompt.h ------------------------------
# The prompt handed to an outside model, and the parse that reads its reply
# back. Both fail quietly: a rule dropped from the prompt shows up as a chat
# window arguing with the user, and a reply shape the parser refuses reads as
# the AI having got it wrong. Neither surfaces anywhere else in the suite.
qt_add_executable(test_theme_prompt
    test_theme_prompt.cpp
)

target_link_libraries(test_theme_prompt PRIVATE
    Qt6::Core
    # ThemeService's validation path reaches QFontDatabase, which needs a
    # QGuiApplication -- same reason test_theme_bundle restates Gui here.
    Qt6::Gui
    Qt6::Test
    crater-core
)

add_test(NAME theme_prompt COMMAND test_theme_prompt)

# -- Bible verse cache -- BibleService::allVerses / verseIndex ----------
# Scripture translation switches read from this cache instead of the whole
# Bible, so a wrong row or a cache that keeps too much (memory) or too
# little (a freeze on the projector) would only show up live. Seeds a tiny
# Bible in the test-mode AppDataLocation.
qt_add_executable(test_bible_cache
    test_bible_cache.cpp
)

target_link_libraries(test_bible_cache PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

# Seeds through the private db/ wrappers, same as test_theme_bundle.
target_include_directories(test_bible_cache PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME bible_cache COMMAND test_bible_cache)

# -- Media relocation -- issue #14 ----------------------------------------
# Rows store the absolute path a managed file had at import. A data folder
# restored under another profile made the startup orphan sweep delete every
# imported picture and video. Covers the sweep, remove(), schedule rows and
# the logo, all against a faked foreign profile path.
qt_add_executable(test_media_relocation
    test_media_relocation.cpp
)

target_link_libraries(test_media_relocation PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

# Drives db::Connection and DbPaths directly, both private to crater-core.
target_include_directories(test_media_relocation PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME media_relocation COMMAND test_media_relocation)

# -- Song credits -- issue #20 --------------------------------------------
# Author, copyright and CCLI through the editor's create and update paths.
qt_add_executable(test_song_credits
    test_song_credits.cpp
)

target_link_libraries(test_song_credits PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

add_test(NAME song_credits COMMAND test_song_credits)

# -- Media import report -- issues #23 and #24 ------------------------------
# wmv sniffing, folder drops, and the skipped-files list importFinished carries.
qt_add_executable(test_media_import_report
    test_media_import_report.cpp
)

target_link_libraries(test_media_import_report PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

add_test(NAME media_import_report COMMAND test_media_import_report)

# -- Bulk actions -- library and schedule multi-select -----------------------
# The one-signal batch calls (SongService::destroyMany / setThemeForSongs,
# MediaService::removeMany, ScheduleService::removeMany / reorder) that
# replace per-item loops in QML.
qt_add_executable(test_bulk_actions
    test_bulk_actions.cpp
)

target_link_libraries(test_bulk_actions PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

# -- Profiles -- ARCHITECTURE.md §12 ---------------------------------------
# Path routing under a non-default profile, the ZIP64 / streaming zip
# additions, and the .craterprofile round trip: export, inspect, import as a
# new profile with every cross-reference remapped, a second merge that adds
# nothing, partial exports, hostile archives and profile duplication. All
# inside the test-mode AppDataLocation, never the Default profile.
qt_add_executable(test_profiles
    test_profiles.cpp
)

target_link_libraries(test_profiles PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

add_test(NAME bulk_actions COMMAND test_bulk_actions)

# Drives the archive engine, zip wrapper and db/ wrappers directly, all
# private to crater-core.
target_include_directories(test_profiles PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME profiles COMMAND test_profiles)
