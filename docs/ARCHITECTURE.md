# Crater (Qt) — Architecture

This document captures the load-bearing decisions for `crater-core` and the
QML app. It exists so we don't accidentally drift off them as we build, and
so future contributors can read *why* things are the way they are without
reverse-engineering it from the code.

The Electron implementation at `../electron/` is the **behavioral
reference** (what does this software *do*?), not the **architectural
reference** (how should it be built?). We are reimplementing, not porting.

---

## 1. Two-target separation: engine vs UI

```
crater-core  (static library, no Qt GUI)   ←  testable in isolation
    │
    └── crater (executable)                ←  thin QML shell
```

`crater-core` owns:

- All persistent data (SQLite for Bible / songs / themes / schedule / app
  settings).
- All long-running work (FTS index rebuild, media import, video decode
  side effects, NDI sender).
- All network surface (the WebSocket remote server, deferred to v1.1).

`crater` (the executable) owns:

- The QML engine and all visible UI.
- Window orchestration (operator console, projection output, NDI mirror).
- IPC-shaped wiring between QML signals and `crater-core` services.

**Why this split**: it lets us write headless unit tests against the engine
(no QML required), keeps `crater-core` portable to a different UI later
(if we ever want a CLI, a remote control daemon, or a Slint UI variant),
and forces us to keep UI logic out of data code — a discipline Electron
versions of this software typically lose within a year.

**Rule**: `crater-core` headers must not include `<QQuickItem>`,
`<QQuickWindow>`, or anything from `Qt6::Quick`. They may include
`Qt6::Core`, `Qt6::Sql`, and `Qt6::Qml` types — `Qml` is allowed because
it provides the `QML_ELEMENT` / `QML_SINGLETON` macros that let services
auto-register with QML, and the Qml module itself has no GUI surface
(that's `Quick`'s job). Enforced by the CMake target dependency
declarations in `core/CMakeLists.txt` — `Qt6::Quick` is not in the link
list, but `Qt6::Qml` is.

---

## 2. SQLite layer choice — raw `sqlite3.h` with a thin RAII wrapper

We considered three options:

| Option           | Pros                                             | Cons |
|---               |---                                               |---   |
| **`QtSql`** (`QSqlDatabase`/`QSqlQuery`) | Cross-DB abstraction, integrates with `QSqlTableModel`, no extra dep | Slow vs raw sqlite3 (per-row `QVariant` boxing), limited FTS5 control, can't easily set `sqlite3_config` flags, awkward access to `sqlite3_prepare_v3` flags we'll need |
| **`SQLiteCpp`** (header-only RAII over sqlite3) | Clean C++ API, RAII safety, no boxing overhead | Extra dep, doesn't speak Qt types — we'd need conversion shims |
| **Raw `sqlite3.h` + our own thin wrapper** | Maximum control (FTS5 tokenizers, custom collations, page-size tuning, mmap, etc.), zero overhead, total ownership of the perf-critical layer | We write and maintain the wrapper |

**Decision: raw `sqlite3.h` with a small wrapper class** in `core/src/db/`.

**Why**: scripture search is the single most important interaction in the
app, and we want full FTS5 control (custom tokenizer for stripping
chapter:verse markers, prefix indexes for typeahead, BM25 ranking
tweaked for biblical text). `QtSql` would force us to drop down to raw
sqlite3 anyway for any of that, and we'd pay the abstraction cost twice.
We get sqlite3 from Qt's bundled `Qt6::Sql` runtime regardless, so there's
no extra dependency.

**Wrapper shape** (sketch):

```cpp
namespace crater::db {
    class Connection {                     // owns sqlite3*
        Connection(const QString& path, OpenMode mode);
        Statement prepare(QStringView sql); // returns RAII Statement
        // ...
    };
    class Statement {                      // owns sqlite3_stmt*
        Statement& bind(int idx, qint64);
        Statement& bind(int idx, QStringView);
        bool step();                       // returns true if row available
        int  columnInt(int idx) const;
        QString columnText(int idx) const;
        // ...
    };
    class Transaction { /* RAII BEGIN/COMMIT/ROLLBACK */ };
}
```

Roughly 300 lines total. Lives in `core/src/db/` (private), never exposed
in service public headers — services return their own typed structs.

**Database files**: stored in `QStandardPaths::AppDataLocation`
(`%APPDATA%/Crater/` on Windows, `~/Library/Application Support/Crater/`
on macOS, `~/.local/share/Crater/` on Linux). Bible and Strong's databases
ship inside the app bundle as read-only resources; on first run we copy
them to writable storage *only* if the user wants to add custom
translations — otherwise we open them read-only directly from the bundle.

---

## 3. Threading model — hybrid (sync fast, async slow)

The temptation in a Qt app is to make every service async with
`QFuture`/`QPromise`. We won't. It adds boilerplate, complicates QML
binding, and is unnecessary for ~99% of operations.

**Rule: services run synchronously on the calling thread for any operation
that completes in under ~5 ms. Anything slower runs on a `QThreadPool`
worker and returns via `QFuture`.**

Practical breakdown:

| Operation                         | Mode      | Why |
|---                                |---        |---  |
| `BibleService::fetchVerse(ref)`   | sync      | Indexed lookup, ~50 µs on cold cache |
| `BibleService::fetchChapter(...)` | sync      | <1 ms even for Psalm 119 (176 verses) |
| `BibleService::search(query)`     | sync      | FTS5 query is sub-ms after index warm |
| `BibleService::rebuildFtsIndex()` | **async** | Multi-second on full Bible — must not block UI |
| `SongService::createSong(...)`    | sync      | Single insert + FTS update |
| `MediaService::importVideo(path)` | **async** | File copy + thumbnail extraction |
| `NdiService::startStream()`       | sync (returns fast); **stream runs on its own thread** |
| `ThumbnailService::generate(...)` | **async** | Decoding video frames |

This keeps QML bindings simple (`text: BibleService.fetchVerse(reference)`
just works) without sacrificing responsiveness. The few async paths use
`QFuture` returned from `QtConcurrent::run`, with QML consuming them via
a small `FutureWatcher` adapter.

**SQLite + threads**: SQLite connections are not safe to share across
threads. Each service holds its own `sqlite3*` per thread (UI thread + each
worker gets its own connection, opened with `SQLITE_OPEN_FULLMUTEX`). Reads
go via WAL mode for concurrent reader scaling.

---

## 4. Service catalog and granularity

One service = one concern. Each service is a `QObject` with `QML_ELEMENT`
+ `QML_SINGLETON` so QML can bind to it as `BibleService.foo(...)`.

| Service             | Owns                                              | Phase |
|---                  |---                                                |---    |
| `BibleService`      | Bible DB, translations, FTS                       | v1    |
| `StrongsService`    | Strong's concordance DB                           | v1    |
| `SongService`       | Song DB, lyrics, FTS                              | v1    |
| `ThemeService`      | Themes (visual styles applied to projection)      | v1    |
| `ScheduleService`   | Service schedules (the "playlist" of items)       | v1    |
| `MediaService`      | Image/video imports, thumbnails                   | v1    |
| `ProjectionService` | What's currently live/preview, transitions        | v1    |
| `OutputService`     | Detect screens, route output windows              | v1    |
| `NdiService`        | NDI sender lifecycle                              | v1    |
| `SettingsService`   | App-wide preferences                              | v1    |
| `RemoteService`     | WebSocket server for phone remote                 | v1.1  |
| `UpdateService`     | Auto-update check + install                       | v1.1  |

**Public surface rule**: service public headers expose only `Q_OBJECT`-friendly
types — `QString`, `int`, `qint64`, `QList<T>`, custom `Q_GADGET` value
structs. Never `sqlite3_stmt*`, never raw pointers to internal state. The
SQLite wrapper is a private implementation detail.

---

## 5. Security model

Crater is a desktop app with three threat surfaces. We design for each.

### 5.1 Untrusted media files

Operators import images, videos, and (eventually) song imports from the
internet. Threats: malformed media exploiting a codec, oversized files
exhausting memory, path traversal on import.

**Mitigations**:

- **Validate at the boundary**: every `MediaService::import*` method
  checks the file extension, magic bytes, and (for video) attempts a probe
  decode in a sandboxed manner *before* registering the file.
- **Size cap**: 4 GB per file, configurable. Reject larger.
- **Path normalization**: `QDir::cleanPath()` and verify the resulting
  path is within the user's media directory before any write.
- **Video decode isolation**: video decoding stays in Qt Multimedia, which
  uses platform decoders (Media Foundation on Windows, AVFoundation on
  macOS, GStreamer on Linux) — these are sandboxed by the OS. We do *not*
  link a custom ffmpeg, which would put codec bugs in our address space.

### 5.2 Remote control (v1.1)

The remote-control WebSocket server exposes operator-level commands
(go-live, scripture lookup, etc.) over the local network. Threats:
unauthenticated access, command injection, DoS.

**Mitigations**:

- **PIN auth on first connect** (4-digit shown in operator console). v2
  upgrades to per-device certificates with QR onboarding.
- **Bind to LAN interfaces only by default**, never `0.0.0.0`.
- **Strict message schema**: incoming messages parsed via a hand-written
  validator, not blindly deserialized into a struct. Unknown fields
  rejected.
- **Rate limit**: max 30 commands/sec per connection.
- **Read-only commands work without PIN; write commands require PIN.**
  Lookup and preview can't damage anything; "Send to Live" can.
- **No file paths in remote commands ever** — the remote can refer to
  schedule items by ID, never by filesystem path.

### 5.3 Data files (Bible / songs / themes)

User-installed Bible translations and theme files are user data, but the
distinction matters because themes can specify fonts, images, and (in the
Electron version) HTML/CSS that gets injected into the projection
renderer. That's a script-injection surface.

**Mitigations**:

- **Themes are declarative data, not code**. Theme files are JSON
  describing token values (colors, font families, padding, transitions),
  validated against a schema. No HTML/CSS strings, no script.
- **Songs are plain text + section markers**, not HTML. The projection
  renderer applies theme tokens to plain text — no `eval`, no
  `setInnerHTML`-equivalent.
- **Bible translations** are SQLite databases. We open them
  `SQLITE_OPEN_READONLY` and never `ATTACH` user-supplied DBs to the main
  connection (which would expose stored procedures / triggers). Each
  translation is its own connection.

### 5.4 What we explicitly *don't* defend against

Be honest about scope.

- **Local user with code execution on the operator machine**: out of
  scope. If an attacker is running code on the AV booth laptop, they own
  the projection.
- **Malicious upstream Bible/song database supplied by trusted user**:
  partial — we open read-only and use parameterized queries, but we trust
  the schema. A maliciously crafted DB could waste resources but not
  escape SQLite.
- **Network attackers on the projector cable**: out of scope.

---

## 6. Performance budget

Targeting Intel HD 4000 / 4 GB RAM / spinning HDD.

| Metric                                    | Budget       |
|---                                        |---           |
| Cold start to operator window visible     | < 1.5 s      |
| Resident memory (operator + projection)   | < 150 MB     |
| Resident memory (with NDI sender active)  | < 200 MB     |
| Frame time, projection window steady-state| < 8 ms (120 Hz headroom) |
| Frame time, projection window during fade | < 16 ms (60 Hz minimum) |
| Bible verse lookup (cached)               | < 1 ms       |
| Bible FTS search (10-char query)          | < 50 ms      |
| Schedule item activation → on-screen      | < 80 ms      |
| Send-to-Live latency                      | < 16 ms (one frame) |

These are not aspirational — they're the gating criteria. If any
service-level operation exceeds its budget, that's a perf bug, not a
design choice.

**Memory discipline**:

- No service holds entire result sets in memory. SQLite cursors / `step()`.
- Bible chapters are loaded on demand, not preloaded.
- Thumbnails are generated on first view and cached on disk under
  `AppDataLocation/thumbnails/`, never reheld in RAM after display.
- QML `ListView` recycles delegates (default behavior — don't disable it).

---

## 7. Schema versioning and migrations

Each SQLite DB has a `PRAGMA user_version`. Migrations are SQL files in
`core/src/db/migrations/<dbname>/V<n>__description.sql`. On startup, each
service:

1. Opens its DB, reads `user_version`.
2. Compares to the highest migration version compiled into the binary.
3. If lower: backup the DB to `<name>.backup-pre-v<n>.sqlite`, then run
   each missing migration in a single transaction.
4. If equal: proceed.
5. If higher (user downgraded the app): refuse to open, prompt user to
   restore from backup.

Migrations are forward-only. We never write a "down" migration — they're
a debugging trap that almost never works correctly.

---

## 8. Crash isolation and recovery

- Crater enables Qt's structured exception handling so SQLite errors
  surface as exceptions, not crashes.
- The projection window is a separate `QQuickWindow` driven by the same
  process. If we ever hit a crash class that justifies it, we can promote
  the projection window to a child process talking over a local socket —
  but we don't pre-optimize for that. One process, one renderer, until
  we have evidence of a class of crash that demands isolation.
- App settings are written via "tmpfile + atomic rename" — no half-written
  JSON on power loss.
- The schedule auto-saves every 5 seconds while modified, plus on every
  item change. Backup copies of the last 10 versions in
  `AppDataLocation/schedules/.history/`.

---

## 9. What goes in `crater-core` vs the executable

Quick reference — when in doubt:

**`crater-core`** if it:
- Touches a database
- Talks to the network
- Reads or writes a file outside QStandardPaths
- Could be unit-tested without a window
- Will eventually need to be reused by a CLI or remote daemon

**Executable / QML** if it:
- Has a visible representation
- Responds to a user gesture
- Holds transient UI state (selected row, hover, focus)
- Needs `QQuickWindow`, `QQuickItem`, or animations

---

## 10. Theme bundle format (`.craterheme` v2)

Themes can reference media (`mediaId`) and fonts (`fontFamily`) that live in
local services. A JSON-only export — which is what v1 was — therefore exports
*pointers* to assets, not the assets themselves, and an import on another
machine finds dangling references. v2 fixes this by making the bundle
self-contained.

### 10.1 Container

`.craterheme` v2 is a **zip archive** (magic bytes `PK\x03\x04`) containing:

```
MyTheme.craterheme        (zip)
├── manifest.json         # format/version + asset index
├── theme.json            # tokens, with mediaRef/fontRef hashes
├── media/
│   └── <sha256>.<ext>    # content-addressed
└── fonts/
    └── <sha256>.<ext>    # content-addressed
```

Content-addressed filenames give us natural dedup (one image referenced
from three nodes ships once) and integrity verification at import (hash of
extracted bytes must equal filename).

### 10.2 The v1 break

**v1 (JSON-only) files are not backward compatible.** Import refuses them
with: *"This file was exported by an older version of Crater. Please
re-export from the original installation."*

This is a deliberate one-way break. v1 couldn't carry media or fonts
anyway, so the population of meaningful v1 exports in the wild is the set
of themes whose authors didn't reference any. Keeping a v1 import path
alive would mean carrying a second parser, a second token-validation
shape (no `mediaRef`/`fontRef`), and a second set of import warnings —
permanently — to support files that produce broken projection state on
import. Not worth the surface area.

The zip wrapper for v2 lives in `core/src/bundle/`, mirroring the §2
"thin wrapper over a C library" approach we already use for SQLite. We
vendor `miniz` (single-file public-domain) rather than depend on Qt's
private `QZipReader`/`QZipWriter`.

### 10.3 Export — confirmation dialog required

Export resolves every `mediaId` and every `fontFamily` the theme actually
references, then opens an `ExportThemeDialog` listing each font's source
file path, byte size, and a license-responsibility warning. The user can
opt individual fonts out per item before the zip is written.

**Why a dialog**: most font files are not legally redistributable. Silent
auto-bundling would put us in the position of having shipped a release
that silently embedded a licensed font into a user's theme exports. The
dialog moves that decision — and that responsibility — to the user.

Media is bundled without per-item opt-out; media in a Crater install is
overwhelmingly user-provided (photos, video clips) where redistribution
intent is unambiguous from the act of exporting.

### 10.4 Import — best-effort, with a report

Per-asset failures during import do **not** abort. Instead they
accumulate into a `ThemeImportReport`:

```cpp
struct ThemeImportReport {
    qint64      themeId;          // 0 if catastrophic failure
    QString     errorMessage;     // catastrophic only
    QStringList mediaWarnings;    // "background.jpg failed magic-byte check"
    QStringList fontWarnings;     // "Inter.ttf failed to register"
};
```

Tokens referencing a failed asset are rewritten to `mediaId = null` /
`fontFamily` (string only, no `fontRef`) and the theme imports anyway.
The UI surfaces warnings in a non-blocking banner.

**Catastrophic failures still roll back the entire import**: bundle not a
zip, `manifest.json` missing/invalid, `theme.json` missing/invalid,
rewritten tokens fail `validateTokensV2`, theme INSERT fails. Catastrophic
rollback walks a `created_files` list and deletes anything we wrote to
`AppDataLocation/{media,fonts}/` during the failed import. SQLite gives
us atomicity for free; the filesystem does not.

Media is extracted to `AppDataLocation/.import-staging/<uuid>/` during the
import. **Startup sweeps any leftover staging dirs** — if the process
was killed mid-import, those temp files would otherwise leak forever.

### 10.5 Asset registration goes through the normal services

Bundled media is imported via `MediaService::importPathSync` — the same
boundary validation from §5.1 (extension, magic bytes, size cap, path
normalization) applies. The theme importer must not bypass it.

Bundled fonts are registered via `FontService::importFontFile`, which
writes to `AppDataLocation/fonts/<hash>.<ext>` and calls
`QFontDatabase::addApplicationFontFromData` so the family is usable
immediately. `FontService` loads all previously-imported fonts at app
startup; without that, a font from a previously-imported theme would
silently fall back to a system substitute after a restart.

### 10.6 Token rewrite happens at import, not at runtime

On disk, v2 tokens hold `{ "mediaRef": "<hash>" }` and (for bundled
fonts) `{ "fontFamily": "Inter", "fontRef": "<hash>" }`. **In the
runtime DB**, tokens still hold the same `mediaId: <int>` and
`fontFamily: <string>` shape they always have. The import path rewrites
refs → local ids before insert, so QML/`ThemedMonitor`/
`ProjectionContentLayer` see no change at all.

This is the load-bearing design choice in §10 — keep the on-disk bundle
format's complexity *out* of the runtime hot path.

---

## 11. Things we're deliberately not doing

- **No ORM.** SQLite + hand-written queries. ORMs leak abstraction at
  exactly the point where we'd want full control (FTS, custom collations,
  pragmas).
- **No global event bus.** Services own their own signals; QML connects
  to them directly. Every event has a clear publisher.
- **No plugin system in v1.** Plugins are a security and maintenance
  multiplier we don't need until the user base requests them.
- **No web view embedded for any UI.** Defeats the entire reason we left
  Electron.
- **No telemetry of any kind without explicit opt-in.** Churches don't
  need their service-prep behavior phoning home.
