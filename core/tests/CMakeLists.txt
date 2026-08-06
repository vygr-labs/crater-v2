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

# ── Narration routing + trust gate, phase 2 — docs/narration.md §5 ─────
# The tier x mode matrix asserted cell by cell, plus NarrationService driven
# end to end through injectTranscript() — the same entry point the operator
# gets in Settings > Narration. No microphone and no speech model: this
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
