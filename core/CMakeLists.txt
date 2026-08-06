# crater-core
#
# Headless engine library: SQLite-backed Bible/song/theme operations,
# and (eventually) NDI sender and the WebSocket remote server.
# UI code (qt/app) consumes this through Q_OBJECT models and services.

add_library(crater-core STATIC
    # SQLite amalgamation — single TU (~250 KB source). Cold compile is ~15 s
    # on MSVC; incremental builds skip it entirely.
    src/third_party/sqlite3.c

    # DB layer — RAII wrappers over the amalgamation + migration runner.
    src/db/Connection.cpp
    src/db/Statement.cpp
    src/db/Transaction.cpp
    src/db/Migrator.cpp
    src/db/DbPaths.cpp
    src/db/FtsQuery.cpp

    # Bundle layer — stored-only ZIP for .craterheme v2 (ARCHITECTURE.md §10).
    src/bundle/Crc32.cpp
    src/bundle/Zip.cpp

    # One-time data import from electron's bundled DBs.
    src/import/CanonicalBibleBooks.cpp
    src/import/ElectronDataImporter.cpp

    # EasyWorship song-library import — RTF lyric extraction + the importer.
    src/import/Rtf.cpp
    src/import/EasyWorshipImporter.cpp

    # Narration — spoken scripture detection (docs/narration.md).
    # Phase 0 is pure text: no audio, no models, no DB.
    src/narration/SpokenNumbers.cpp
    src/narration/CitationDetector.cpp
    # Phase 3 rides the existing FTS5 trigram index — no new index, no model.
    src/narration/QuotationMatcher.cpp
    # Phase 4: the semantic path. The index and its gates are complete and
    # tested; they stay inert until a TextEmbedder implementation and a built
    # index file exist (docs/narration.md §7.2).
    src/narration/AllusionIndex.cpp
    src/narration/AllusionMatcher.cpp
    # Phase 1 is capture and recognition. WhisperRecognizer.cpp compiles
    # either way — its real body is behind CRATER_WITH_WHISPER and the stub
    # keeps the type nameable when the option is off.
    src/narration/AudioRing.cpp
    src/narration/VoiceGate.cpp
    src/narration/AudioTap.cpp
    src/narration/WhisperRecognizer.cpp

    # AUTOMOC needs to see the QObject headers under src/ too — these aren't
    # in include/ because narration's only public type is HeardReference.
    src/narration/SpeechRecognizer.h
    src/narration/AudioTap.h
    src/narration/WhisperRecognizer.h

    # Public bootstrap entry point — runs migrations on all DBs.
    src/Bootstrap.cpp

    # Services.
    src/Version.cpp
    src/BibleService.cpp
    src/StrongsService.cpp
    src/SongService.cpp
    src/CollectionService.cpp
    src/ScheduleService.cpp
    src/ThemeService.cpp
    src/MediaService.cpp
    src/FontService.cpp
    src/OutputService.cpp
    src/ProjectionService.cpp
    src/SettingsService.cpp
    src/NarrationService.cpp
    src/WorkingTheme.cpp
    src/LyricsDSL.cpp
    src/LyricsService.cpp

    # Headers (Q_OBJECT + Q_GADGET). Listed explicitly so AUTOMOC scans them —
    # without this, AUTOMOC walks .cpp #includes but doesn't always discover
    # headers in `include/` when they're separated from `src/`.
    include/crater/BibleService.h
    include/crater/StrongsService.h
    include/crater/SongService.h
    include/crater/CollectionService.h
    include/crater/ScheduleService.h
    include/crater/ThemeService.h
    include/crater/MediaService.h
    include/crater/FontService.h
    include/crater/OutputService.h
    include/crater/ProjectionService.h
    include/crater/SettingsService.h
    include/crater/NarrationService.h
    include/crater/ElectronDataImporter.h
    include/crater/EasyWorshipImporter.h
    include/crater/WorkingTheme.h
    include/crater/value/Translation.h
    include/crater/value/Book.h
    include/crater/value/Verse.h
    include/crater/value/HeardReference.h
    include/crater/value/SearchHit.h
    include/crater/value/StrongsEntry.h
    include/crater/value/StrongsWord.h
    include/crater/value/StrongsBibleVerse.h
    include/crater/value/StrongsSection.h
    include/crater/value/Song.h
    include/crater/value/SongSection.h
    include/crater/value/Collection.h
    include/crater/value/SavedSchedule.h
    include/crater/value/Theme.h
    include/crater/value/ThemeImportReport.h
    include/crater/value/Screen.h
    include/crater/value/MediaItem.h
    include/crater/value/UserFont.h
    include/crater/value/OutputThemeSlots.h
    include/crater/value/OutputBinding.h
    include/crater/LyricsDSL.h
    include/crater/LyricsService.h
)

target_include_directories(crater-core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        # sqlite3.h is included only by the DB wrappers. Kept PRIVATE so
        # consumers of crater-core never see sqlite3.h directly — services
        # expose only Q_OBJECT-friendly types (ARCHITECTURE.md §4).
        ${CMAKE_CURRENT_SOURCE_DIR}/src/third_party
)

target_link_libraries(crater-core
    PUBLIC
        Qt6::Core
        Qt6::Concurrent  # QtConcurrent::run for off-thread import + FTS rebuild
        # Qml gives us QML_ELEMENT / QML_SINGLETON macros so services can
        # auto-register with QML. NOT a GUI dependency — that's Qt6::Quick,
        # which crater-core must never link.
        Qt6::Qml
    PRIVATE
        # OutputService uses QGuiApplication::screens() / QScreen. Qt6::Gui is
        # the system display layer — not Qt6::Quick (that's the renderer). We
        # absorb this as a PRIVATE dep so QScreen never appears in crater-core's
        # public headers — services expose only value types (Screen Q_GADGET).
        Qt6::Gui
        # Qt6::Pdf wraps pdfium (Chromium's hardened PDF engine) and is the
        # ONLY supported route — per ARCHITECTURE.md §5.1's policy of using
        # OS/Qt-vetted decoders rather than linking a custom parser, which
        # would put codec bugs inside our address space. Used by MediaService
        # for page-count probing at import time and async page rasterization
        # via QtConcurrent. No Quick dependency: we render to QImage and the
        # app-side PdfPageImageProvider feeds those QImages into QML's plain
        # Image element via the standard image:// URL scheme. crater-core
        # stays Quick-free per §1.
        Qt6::Pdf
        # Qt6::Multimedia is here for narration's AudioTap only — QAudioSource
        # gives us a QIODevice we pull mic PCM from. PRIVATE because no public
        # header exposes an audio type: the tap normalizes everything to
        # 16 kHz mono float before anything else in crater-core sees it.
        Qt6::Multimedia
        # NOTE: deliberately do NOT link Qt6::Sql. We build sqlite3 ourselves
        # with custom compile flags (FTS5, THREADSAFE=2, DQS=0). See the plan's
        # "Deviations from Electron" table.
)

target_compile_definitions(crater-core
    PUBLIC
        CRATER_VERSION_STRING="${PROJECT_VERSION}"
    PRIVATE
        # SQLite build-time tuning. These flags affect sqlite3.c only; other
        # TUs in this target ignore them.
        SQLITE_ENABLE_FTS5                       # FTS5 + trigram tokenizer
        SQLITE_THREADSAFE=2                      # multi-thread mode (one conn per thread)
        SQLITE_DEFAULT_WAL_AUTOCHECKPOINT=1000   # checkpoint roughly every 4 MB of WAL
        SQLITE_DQS=0                             # no double-quote string literals (catches bugs)
        SQLITE_USE_URI=1                         # support file:?... open URIs
        SQLITE_LIKE_DOESNT_MATCH_BLOBS           # small optimization
        SQLITE_DEFAULT_MEMSTATUS=0               # skip memory accounting overhead
        SQLITE_OMIT_DEPRECATED                   # smaller binary
        SQLITE_OMIT_LOAD_EXTENSION               # security + smaller binary
)

# Silence warnings inside sqlite3.c — it's vendor code and we don't want to
# patch it just to make MSVC's high warning levels happy.
if(MSVC)
    set_source_files_properties(src/third_party/sqlite3.c
        PROPERTIES COMPILE_OPTIONS "/W0")
else()
    set_source_files_properties(src/third_party/sqlite3.c
        PROPERTIES COMPILE_OPTIONS "-w")
endif()

# Bundle schema migrations as Qt resources at qrc:/migrations/<db>/V*.sql.
# Migrator reads them at runtime via QDirIterator over the resource path.
qt_add_resources(crater-core "crater_migrations"
    PREFIX "/migrations"
    BASE   "${CMAKE_CURRENT_SOURCE_DIR}/src/db/migrations"
    FILES
        src/db/migrations/bibles/V001__init.sql
        src/db/migrations/bibles/V002__fts_apostrophe_normalize.sql
        src/db/migrations/songs/V001__init.sql
        src/db/migrations/songs/V002__fts_marker_strip.sql
        src/db/migrations/songs/V003__collections.sql
        src/db/migrations/songs/V004__fts_apostrophe_normalize.sql
        src/db/migrations/app/V001__init.sql
        src/db/migrations/app/V002__media.sql
        src/db/migrations/app/V003__theme_nodes.sql
        src/db/migrations/app/V004__media_duration.sql
        src/db/migrations/app/V005__media_pdf.sql
        src/db/migrations/app/V006__remove_builtin_themes.sql
        src/db/migrations/app/V008__user_fonts.sql
        src/db/migrations/app/V009__media_display.sql
)

# ── Speech recognition (docs/narration.md §7.1) ────────────────────────
#
# OFF by default, and deliberately so. whisper.cpp is a source dependency
# fetched at configure time and it materially lengthens a cold build, which
# nobody working on themes or the schedule should have to pay for. With it
# off, WhisperRecognizer compiles to stubs that fail loudly and
# NarrationService falls back to NullRecognizer.
#
# Enable with: cmake -S . -B build -DCRATER_WITH_WHISPER=ON
#
# Models are NOT fetched — they're downloaded separately and pointed at by
# the operator. Nothing here phones home at build time or at run time.
option(CRATER_WITH_WHISPER "Build the whisper.cpp speech recognizer for narration" OFF)

if(CRATER_WITH_WHISPER)
    include(FetchContent)

    # Pinned, not floating. An ASR backend that silently changes its decoding
    # behaviour between builds would make every precision number we measure
    # in phases 3-5 unreproducible.
    FetchContent_Declare(whisper_cpp
        GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp.git
        GIT_TAG        v1.7.4
        GIT_SHALLOW    TRUE
    )

    set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
    set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(whisper_cpp)

    target_link_libraries(crater-core PRIVATE whisper)
    target_compile_definitions(crater-core PRIVATE CRATER_WITH_WHISPER)
endif()

add_library(Crater::Core ALIAS crater-core)

# Headless unit tests. Off by default so dev rebuilds stay snappy; enable
# with `cmake -DCRATER_BUILD_TESTS=ON` (or via the test preset). Tests live
# under tests/ as their own subdir to keep this CMakeLists scannable.
option(CRATER_BUILD_TESTS "Build crater-core unit tests" OFF)
if(CRATER_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
