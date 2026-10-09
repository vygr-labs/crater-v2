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

# V013 does the same for songs: Plum & Rose on fresh installs, and an
# upgrade keeps whatever song theme the congregation already sees.
qt_add_executable(test_song_themes
    test_song_themes.cpp
)

target_link_libraries(test_song_themes PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

target_include_directories(test_song_themes PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME song_themes COMMAND test_song_themes)
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

# -- Help links -- Settings > Help, the F1 dialog, the empty schedule ----
# Every address must be a real https link, since a blank or mistyped one
# only shows up when an operator presses the button.
qt_add_executable(test_help_links
    test_help_links.cpp
)

target_link_libraries(test_help_links PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

add_test(NAME help_links COMMAND test_help_links)

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

# -- Bundled Bible import -- ElectronDataImporter first run and upgrade --
# A release can ship a different Bible set. An install that already ran the
# first import only takes the translations it lacks, keeps what it has, and
# indexes the new ones once. Writes its fixture to <exe-dir>/legacy/.
qt_add_executable(test_bible_import
    test_bible_import.cpp
)

target_link_libraries(test_bible_import PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

target_include_directories(test_bible_import PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME bible_import COMMAND test_bible_import)

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

# ── Scripture narration, phase 0 — docs/narration.md §4 ────────────────
# Spoken-number normalization and the citation detector, exercised against
# transcript fixtures. Pure text in, references out: no microphone, no model,
# no database, so this runs anywhere CTest does.
qt_add_executable(test_reference_detector
    test_reference_detector.cpp
)

target_link_libraries(test_reference_detector PRIVATE
    Qt6::Core
    # The detector itself is Core-only, but crater-core's Qt6::Gui dependency
    # is PRIVATE and doesn't propagate — restated here for the same reason
    # test_lyrics_dsl restates it.
    Qt6::Gui
    Qt6::Test
    crater-core
)

# The detector and its number parser are PRIVATE headers under src/ — only
# HeardReference is public. The test drives them directly, so restate the
# private include dir the same way test_theme_bundle does for bundle/Zip.h.
target_include_directories(test_reference_detector PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME reference_detector COMMAND test_reference_detector)

# ── Narration audio plumbing, phase 1 — docs/narration.md §7.1 ─────────
# AudioRing and VoiceGate over synthetic PCM. No microphone, no model: the
# gate is a deterministic state machine and the ring is pure bookkeeping.
# AudioTap is excluded on purpose — it needs a real capture device.
qt_add_executable(test_voice_gate
    test_voice_gate.cpp
)

target_link_libraries(test_voice_gate PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

target_include_directories(test_voice_gate PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME voice_gate COMMAND test_voice_gate)

# ── Deepgram message assembly — docs/narration.md §7.4 ─────────────────
# Recorded server messages replayed into the recognizer. No socket, no key,
# no network: what is tested is how interim, final and end-of-utterance
# messages become partial() and transcribed().
qt_add_executable(test_deepgram_recognizer
    test_deepgram_recognizer.cpp
)

target_link_libraries(test_deepgram_recognizer PRIVATE
    Qt6::Core
    Qt6::Test
    crater-core
)

target_include_directories(test_deepgram_recognizer PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME deepgram_recognizer COMMAND test_deepgram_recognizer)

# ── Narration routing + trust gate, phase 2 — docs/narration.md §5 ─────
# The tier x mode matrix asserted cell by cell, plus NarrationService driven
# end to end through injectTranscript(), the transcript path minus the
# microphone, and testTranscript(), the Settings > Narration test box. No microphone and no speech model: this
# covers what the system DECIDES, which is the part that can put a wrong
# verse in front of a congregation.
qt_add_executable(test_narration_service
    test_narration_service.cpp
)

target_link_libraries(test_narration_service PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

# TrustGate.h is a PRIVATE header under src/ — only HeardReference and the
# service itself are public. Restated for the same reason the other narration
# tests restate it.
target_include_directories(test_narration_service PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME narration_service COMMAND test_narration_service)

# ── Verbatim quotation, phase 3 — docs/narration.md §2 ─────────────────
# Fixture corpus for the matcher's own logic, then the SAME matcher against
# the operator's real bibles.sqlite through the real FTS5 index. The second
# half is the one that can prove a phrase is unique among 31,102 verses; it
# QSKIPs with a reason when no database is installed.
qt_add_executable(test_quotation_matcher
    test_quotation_matcher.cpp
)

target_link_libraries(test_quotation_matcher PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

# QuotationMatcher.h and DbPaths.h are both PRIVATE headers under src/.
target_include_directories(test_quotation_matcher PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME quotation_matcher COMMAND test_quotation_matcher)

# ── Semantic allusion, phase 4 — docs/narration.md §7.2, §7.3 ──────────
# The int8 index (build, save, load, brute-force scan) and the three
# distinctiveness gates, driven with synthetic unit vectors. No embedding
# model is involved and none is needed: quantization error, file-format
# round-tripping, ranking and gating are all independent of which model
# produced the numbers. Also measures the flat scan over a full 31,102-row
# corpus, which is the claim the no-ANN decision rests on.
qt_add_executable(test_allusion_index
    test_allusion_index.cpp
)

target_link_libraries(test_allusion_index PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

target_include_directories(test_allusion_index PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME allusion_index COMMAND test_allusion_index)

# ── BERT WordPiece tokenization — docs/narration.md §7.2 ───────────────
# Exact token ids against the bundled bert-base-uncased vocabulary. Pinned to
# values rather than shapes because a wrong tokenizer does not fail: it hands
# the model plausible ids and gets back a confident vector pointing nowhere.
qt_add_executable(test_wordpiece_tokenizer
    test_wordpiece_tokenizer.cpp
)

target_link_libraries(test_wordpiece_tokenizer PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

target_include_directories(test_wordpiece_tokenizer PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

add_test(NAME wordpiece_tokenizer COMMAND test_wordpiece_tokenizer)

# ── The embedder, against the real model — docs/narration.md §7.2 ──────
# The only test that can distinguish a correct embedding from a confidently
# wrong one: tokenization, CLS pooling and normalization each produce a
# well-formed unit vector whether they are right or not, so this asks whether
# the resulting geometry actually means anything. Skips with a reason when the
# operator-supplied model is not installed.
qt_add_executable(test_onnx_embedder
    test_onnx_embedder.cpp
)

target_link_libraries(test_onnx_embedder PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Test
    crater-core
)

target_include_directories(test_onnx_embedder PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

# onnxruntime.dll must sit beside the test binary for the same reason it must
# sit beside crater.exe — crater-core links it PRIVATE.
if(CRATER_WITH_EMBEDDINGS AND CRATER_ORT_RUNTIME_DLL)
    add_custom_command(TARGET test_onnx_embedder POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CRATER_ORT_RUNTIME_DLL}"
            "$<TARGET_FILE_DIR:test_onnx_embedder>"
        VERBATIM)
endif()

add_test(NAME onnx_embedder COMMAND test_onnx_embedder)
