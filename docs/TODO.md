# Crater (Qt) — Remaining Work

Punch-list of what's left before v1 / v1.1. Crater is essentially
feature-complete for a v1 core (Bible, Songs, Themes + editor, Schedule,
Media, Fonts, Projection + transitions, multi-monitor routing, NDI, and the
operator console are all done). What remains splits into: a couple of
genuinely-unbuilt features, a set of settings toggles that render but do
nothing yet ("Soon"), v1.1-deferred items, tuning/loose ends, and a
forward-looking competitive-parity roadmap (what ProPresenter has that we don't).

Status legend: 🔴 unbuilt feature · 🟡 UI exists but inert · 🔵 v1.1 deferred · 🟢 works, rough edge · 🟣 v2 / competitive parity

Line references are anchors, not guarantees — verify against current code before starting an item.

---

## 🔴 Features not built yet

### Strong's concordance — DONE (packaging pending)
Shipped: `StrongsService` (`core/src/StrongsService.cpp`) over two read-only bundled DBs (dictionary + KJV-with-Strong's), the `StrongsTab` with a Dictionary view (number/keyword search, language-scoped, full definition) and an interlinear Reader view (tappable Greek/Hebrew word tags → definition), and projection of a selected definition as auto-sized slides (falls back to the scripture theme).
- [x] `StrongsService` — lookup / search / browse / sections / resolveReference / chapter / tokenize.
- [x] Dictionary tab view + interlinear Reader view (`app/qml/tabs/strongs/`).
- [x] Projection render for a selected Strong's definition (`kind:"strongs"`, no-theme gates added).
- [x] **Packaging (scripts + CI)**: release.ps1 / release.sh stage both `strongs-*.sqlite` into `<exe>/legacy/` (three-tier resolve: `packaging/` cache → sibling electron tree → `data-v1` release download, SHA-256 verified); both CI workflows cache them; `.gitignore` updated. Installer picks up `legacy/` automatically.
- [x] **Uploaded both DBs to the `data-v1` GitHub release** so CI's download fallback works on a cold cache. SHA-256s baked into the release scripts: dictionary `27890d55…`, bible `8934fdf6…`.

Strong's is now fully shipped end-to-end (engine + UI + projection + packaging + CI).
- [ ] Dedicated `strongs` theme kind + per-output pinning (currently reuses the scripture theme). Optional.
- [ ] Minor: Dictionary and Reader share one search box (keyword vs reference), so toggling views leaves stale text.

### Song collections — DONE
Shipped: `CollectionService` over `collections` + `collection_songs` (V003 migration in songs.sqlite; many-to-many, cascade delete). Favorites stays a separate `is_favorite` flag.
- [x] `CollectionService` — create / rename / duplicate / destroy / addSong / removeSong / songIdsFor + a `collections` property with counts.
- [x] Sidebar "My Collections" lists real collections as expandable subgroups; bottom "+ ⚙" strip is live (create + manage the selected collection). Selection encoded as `collection:<id>`.
- [x] SongsTab filters to a selected collection; song context menu has an "Add to Collection…" submenu + "Remove from Collection".
- [ ] Optional later: drag-reorder of collections and of songs within a collection (schema has `sort_order`, no UI yet).

### Global search (command-palette)
Today search is **per-tab only** — each library tab owns its own `TabSearchBar`
bound to `AppState.searchText.<tab>` + `AppState.librarySearchMode.<tab>`. There
is no single entry point that searches *across* libraries. Build one.
- [ ] Global shortcut (e.g. `Ctrl+K` / `Ctrl+F`) that opens a floating search
      overlay with a single text input, mounted in `ModalLayer.qml` and driven
      by new `AppState` state (`globalSearch.open`, `globalSearch.query`).
- [ ] Fan out the typed query across the existing services and merge results into
      one grouped, ranked list: Scripture (`BibleService::search`), Songs
      (`SongService::search`), Strong's (`StrongsService::search`), Media
      (`MediaService`), Themes (`ThemeService`), Schedule items. Debounce like
      `ScriptureTab._debouncedQuery` (`ScriptureTab.qml:51-58`).
- [ ] Grouped results with keyboard nav (↑/↓ across groups, Enter to act) and a
      per-row primary action: reveal in its tab, add to schedule, or send to
      Preview/Live. Reuse `SearchHit`/`Song` value types where possible.
- [ ] Empty / loading / no-result states; remember last query per session.

---

## 🟡 Settings that render but do nothing (disabled + "Soon" badge)

Each needs backing infrastructure, not just flipping `enabled: true`.

### Appearance (`app/qml/dialogs/settings/AppearanceSection.qml`)
- [x] Theme picker (**Dark / Light / Midnight / Auto**) — DONE. `Theme.qml` now
      holds a palette registry (`_darkPalette` / `_lightPalette` /
      `_midnightPalette`) and `Theme.color` is a live binding on the active
      palette, so every `Theme.color.*` site recolors instantly with no restart.
      Selection persists via the existing `SettingsService.themeMode`;
      **Auto** follows the OS via `Qt.styleHints.colorScheme`. Operator-console
      only (projected slides use their own `.craterheme` themes). Add a theme =
      add a palette QtObject + one row to `Theme.themes`. (QML-only, no C++.)
- [x] **Tier 1 extra themes** — DONE. Added **High Contrast** (accessibility:
      pure-black surfaces, AA/AAA text at every tier, bright saturated accents,
      cyan-on-black brand), **Dusk** (warm low-blue dark for dim booths /
      long rehearsals), and **Sepia** (warm parchment light for long reads,
      ties to the warm-gold heritage). Same mechanism — one palette QtObject +
      one `Theme.themes` row each. Picker `Flow` wraps to 6 swatches unchanged.
- [x] **Tier 2/3 extra themes** — DONE. Added all eight as full 45-token
      palette QtObjects (+ registry row + `paletteFor()` case each). *Tier 2
      established palettes*: **Nord** (frost-cyan brand), **Solarized
      Dark/Light** (cyan brand, kept for teal continuity), **Gruvbox** (muted
      blue-teal brand), **Dracula** (purple brand). *Tier 3 brand-hue variants
      of Dark* (Dark's neutrals, only the brand family swapped): **Royal
      Purple** (violet-800), **Amber** (goldenrod), **Ecclesial Blue**
      (blue-800). Picker now shows 14 swatches + Auto; the `Flow` wraps.
      Note: **Amber** is the one to watch — its gold selection accent shares a
      temperature with Preview champagne / Warning amber; drop it first if the
      warm hues blur.
- [ ] *Deferred refactor (not blocking):* base-palette + per-theme override
      layer so a variant is ~5 tokens instead of a full ~45-token copy. Today
      all 14 palettes spell out every token (no inheritance) — fine at this
      count, worth doing before the next wave of variants.
- [ ] **Language** switcher, `:143-156` — no i18n catalog.

### Scripture (`app/qml/dialogs/settings/ScriptureSection.qml`)
- [x] **Highlight current verse** — DONE. `SettingsService.highlightCurrentVerse`
      (default off). When on, `ScriptureTab.buildItemFromVerses` bakes a
      multi-verse passage into one page per verse (whole passage shown, active
      verse bright, rest dimmed `{color=gray}`), so the existing slide nav walks
      the highlight — no `ProjectionService`/render-layer change. Dimming is
      color-only so the auto-fit size is stable across pages.
- [x] **Show book:chapter in footer** — DONE. `SettingsService.showScriptureFooter`
      (default off) + a render-time reference-line overlay in
      `ProjectionContentLayer` (composed from `scriptureRef`), drawn on top of
      the theme so it's honored regardless of theme authoring; hides when blanked.

### Song (`app/qml/dialogs/settings/SongSection.qml`)
- [x] **Default theme** picker — DONE. A `Combobox` bound to
      `ThemeService.defaultFor/setDefaultFor("song")` — the existing kv-backed
      per-kind default (a second entry point to ThemesTab's "Set as default"),
      not a new `SettingsService` key.
- [x] **Auto-advance slides** — DONE. `SettingsService.autoAdvance` /
      `autoAdvanceDelaySeconds` / `autoAdvanceLoop`; a `Timer` in `LivePanel`
      re-arms a full delay on each page change and is gated on a live,
      multi-slide, non-blanked item. Delay + stop/loop controls added.

### NDI (`app/qml/dialogs/settings/NdiSection.qml`)
- [x] **Quality / format** selector — DONE. `SettingsService.ndiPixelFormat`
      (bgra/bgrx/uyvy) + `ndiResolution` (native/720p), read by `NdiService` at
      broadcast start. Both frame builders route through `sendResolvedFrame()`:
      BGRA/BGRX direct, a BT.709 UYVY 4:2:2 packer (second ping-pong buffer),
      and an optional `scaled()` downscale. Format/Resolution pickers replace
      the disabled chip. *UYVY color path is unverified on a real receiver.*
- [ ] **Include audio**, `:231-254` — **deferred (large, not a toggle).** No PCM
      tap exists: QtMultimedia's `QAudioOutput` is playback-only (no sample
      callback / probe), and the NDI wrapper (`NdiAbi.h`) has no audio ABI. Needs
      (a) mechanical NDI audio-frame ABI + `clock_audio=true`, and (b) a real
      capture subsystem — either re-architecting `MediaPlaybackService` audio
      onto a `QAudioSink`/`QIODevice` we own, or Windows WASAPI loopback. Scope
      also needs defining (today only foreground video on the open primary output
      makes sound; theme-video backgrounds are muted). Row stays "Soon".

---

## 🔵 v1.1 (explicitly deferred; preview UI exists)

### Phone remote-control server
The interactive remote (go-live / next / prev / blank / search / add-to-schedule from a phone).
- [ ] WebSocket/TCP control server + message-schema validator + PIN auth + LAN-bind + rate limit (see architecture.md §5.2). None exists.
- [ ] Enable the disabled preview controls in `RemoteControlSection.qml:167-222` (enable toggle, port, require-password).
- Note: `BrowserCastService` (`app/src/BrowserCastService.cpp`) is real and working, but it's a **one-way, view-only** MJPEG/video cast to a TV/phone browser — not a control channel. Self-documented as "temporary / removable."

### Multi-output (stage monitor + dynamic outputs)
- [ ] `OutputService` already has the full registry / theme-slot / transition plumbing (`registerOutput`, `stage` builtin), but **no window renders anything except `primary` and `ndi`**. Wire a real Stage Monitor window + generic dynamic-output windows to consume the existing bindings (`app/qml/components/ProjectionScene.qml:18` marks stage "reserved for v1.1").
- [ ] The Projection settings rows are aspirational mockups: NDI toggle `ProjectionSection.qml:370-411`, Stage Monitor `:415-456`, "Add output" (decorative) `:459-487`, "Clear output when idle" (no idle timer) `:503-527`.
- [ ] Theme context-menu "Set for Stage Monitor (Soon)" (`ThemesTab.qml:738-746`) writes to `OutputService.setThemeIdFor("stage", …)` but nothing consumes it yet.

### Auto-update
- [ ] No `UpdateService` / in-app updater. Updates are manual via `scripts/release.{ps1,sh}` + the CI release workflow only.

---

## 🟣 Competitive gaps vs ProPresenter (v2 / market-parity roadmap)

Forward-looking, beyond the v1/v1.1 punch-list above: features ProPresenter (the
incumbent) ships that Crater does not. Core slide-driving is already at rough
parity (Bible, Songs, Themes + editor, Schedule, Media, transitions, NDI out,
operator console) — the gaps are mostly **production / integration**, not
presentation. Ordered by how much a real church deployment feels each one.

Several PP features already have a home above and are **not** repeated here:
Stage Display → *Multi-output* (§🔵), interactive phone control → *Phone
remote-control server* (§🔵), in-app updates → *Auto-update* (§🔵), cross-library
search → *Global search* (§🔴), verse highlight / book:chapter footer /
auto-advance → *Scripture & Song settings* (§🟡).

### Tier 1 — biggest deployment blockers
- [ ] **Planning Center Online + CCLI SongSelect integration.** Import service
      plans from PCO and pull song lyrics legally from SongSelect, with CCLI
      usage reporting. The single biggest "why we bought ProPresenter" feature
      for US churches. New `PlanningCenterService` / `SongSelectService` (OAuth +
      REST), mapping imports onto the existing `ScheduleService` + `SongService`.
- [ ] **Props / lower-thirds / overlay layer.** A persistent overlay drawn
      *above* the current slide and toggled independently — logos, name tags,
      sponsor bugs, "baby in the nursery" banners — without disturbing what's
      live. New always-on output layer in `ProjectionScene.qml` + a Props
      library/tab; distinct from the theme/content layer.
- [ ] **Timers, clocks & live messages.** Countdown-to-service loops, count-up
      timers, wall clocks, and free-text messages pushed to the projection /
      stage screens on the fly. Feeds naturally into the Stage Display work.

### Tier 2 — strong differentiators
- [ ] **Live video input as a source.** Bring a camera / NDI / Syphon feed in as
      a slide background or full-screen source. Today NDI and `BrowserCastService`
      are **output-only** — nothing comes in. Needs a capture/input path
      (`QMediaCaptureSession` / NDI receiver) surfaced as a media source.
- [ ] **Multiple independent outputs + masks / edge-blend / warp.** Drive several
      screens with *different* content, plus screen-shaping for projection
      mapping. Builds on the existing `OutputService` registry (already models
      >2 outputs) once the Multi-output windows (§🔵) land.
- [ ] **Built-in recording & streaming.** Record the program output to disk and
      stream to RTMP / YouTube / Facebook. No capture pipeline exists today.
- [ ] **MIDI / macros / triggers / "Looks."** Hardware (MIDI) control, macro
      recording, and one-tap multi-layer output presets ("Looks"). Absent.
- [ ] **Audio bin / playlists / background audio.** A managed audio library
      separate from video (walk-in music, stingers). Crater plays a video's own
      track via `MediaPlaybackService` but has no audio-only library or playlist.

### Tier 3 — nice-to-have / scripted-service features
- [ ] **Song arrangements.** Multiple reorderable verse/chorus arrangements per
      song (the LyricsDSL already models sections; an arrangement is an ordered
      sequence over them + a picker). Confirm against the current `SongService`
      before starting.
- [ ] **Multi-language / dual-translation lines.** Two translations or languages
      rendered on one slide at once (e.g. native + English).
- [ ] **Timeline / SMPTE timecode sync** for fully scripted, time-locked services.
- [ ] **Network sync between operator machines** (master/follower), so a backup
      or secondary station mirrors live state. Crater is single-machine.
- [ ] **Free-form multi-object slide editor** — arbitrary text boxes + shapes +
      multiple media per slide. Crater is template/theme-driven, not free
      composition; a large editor rework, listed for completeness.
- [ ] **Chord charts** on the stage / musician display.

**Where Crater already leads PP:** the **Strong's concordance + interlinear
reader** has no real ProPresenter equivalent — a genuine differentiator for
study-heavy churches. NDI output is built-in (PP tiers some outputs behind
paid editions), and the `.craterheme` theme editor + projection transitions
are solid.

---

## 🟢 Tuning / loose ends (works, but rough)

### NDI
- [ ] On-demand render mode (latest commit `d08c17c`) ships **off-by-default** (`app/src/NdiRenderer.cpp:349`, toggle `NdiSection.qml:350`) — finish validating, then decide default.
- [ ] Canvas size **hardcoded 1920×1080** (`NdiRenderer.cpp:32-33`) — the headless path won't render themes whose canvas isn't 1080p. Parameterize.
- [ ] Two capture paths advertise **different frame rates** — legacy `30000/1001` (`NdiService.cpp:516`) vs headless `60000/1001` (`NdiService.cpp:576`). Reconcile.

### Search quality — Scripture & Songs — mostly DONE
Both FTS5 **trigram** searches (Scripture `BibleService::search`, Songs
`SongService::search`) were raised to a "great search" bar. The core wins:
- [x] **Safe query sanitization** — new shared `crater::db::buildFtsQuery`
      (`core/src/db/FtsQuery.cpp`) turns raw input into a valid FTS5 MATCH:
      every term becomes a quoted string literal (operator chars inert), sub-3-
      char terms the trigram tokenizer can't match are dropped, and a small
      operator set is honored — `"quoted phrases"`, `a OR b`, `-term`/`NOT`.
      Fixes the whole silent-empty class (`God is love` used to return nothing
      because `is` zeroed the AND; a stray quote used to be a swallowed syntax
      error). Wired into both services.
- [x] **Ranked results.** Songs now use a **title-weighted** `bm25(songs_fts,
      10, 6, 1)` (title ≫ author ≫ lyrics) instead of equal weights; Scripture
      was already bm25-ordered. Both `ORDER BY score`.
- [x] **Match highlighting.** Shared `SearchFormat` singleton
      (`app/qml/SearchFormat.qml`) bolds matched terms in the verse text, song
      title/author, and the lyric snippet (`Text.StyledText`). *Note:* the FTS
      tables are **contentless**, so SQLite's `snippet()`/`highlight()` can't be
      used — highlight is built from the joined-back text instead.
- [x] **Matched-lyric snippet.** `Song.snippet` carries a word-boundary excerpt
      of the first matching lyric line (`SongService::makeSnippet`), shown in the
      result row in place of the author subtitle for lyrics hits.
- [x] **Search all translations.** Scripture gear-menu toggle
      (`AppState.scriptureSearchAllTranslations`) searches every imported version
      at once; each hit shows its own translation chip.
- [x] **Strong's LIKE escaping** — `%`/`_` in the query are now escaped
      (`ESCAPE '\'`) so they match literally instead of acting as wildcards.

Remaining follow-ups (nice-to-have, not blocking):
- [ ] **More scoping.** Scripture book / testament filters; Songs field-scoped
      (title-only vs lyrics) + filter by collection — the title/author modes are
      still in-memory JS substring filters (`SongsTab.qml`), not FTS.
- [ ] **Typo tolerance** for Songs (edit-distance fallback when FTS returns
      nothing) so a badly-misspelled title still surfaces. Trigram already gives
      substring tolerance; this is the last mile.
- [ ] **Recent-search history** + sort options in the result affordances (the
      matched-snippet affordance itself is done above).
- [ ] Highlight the current verse on the **projected slide** once "Highlight
      current verse" lands (`ScriptureSection.qml:76-100`).

### Media

#### Image / video display options — DONE
Per-item presentation for projected image/video items, plus an app-wide default.
- [x] **Persistence** (`V009__media_display.sql`): `fit_mode`, `crop_x/y/w/h`,
      `loop_video`, `muted` columns on `media`; surfaced on `MediaItem` and set
      via `MediaService.setFitMode` / `setDisplayOptions`.
- [x] **Fit mode** — Contain / Cover / Stretch (+ a "Default" sentinel that
      follows the global `SettingsService.mediaDefaultFit`). Resolved and applied
      inside `MediaMonitor` for image AND video across all surfaces (projection
      scene, Preview/Live mini-monitors, logo).
- [x] **Crop** — a saved normalized rect per item (was "deferred" for images);
      images clip via `Image.sourceClipRect`, video via a clipped/scaled
      `VideoOutput` (Qt 6 has no video source-clip). Edited in the new **Edit
      media** modal (crop against the still/first-frame poster). Applied at
      go-live through `item.cropRect` → `goLiveWithCrop`.
- [x] **Video loop / mute** — per item; loop threads through the shared
      `MediaPlaybackService` (per-URL, last-writer-wins), mute ORs into the audio
      routing.
- [x] **UI** — new **Settings ▸ Media** pane (global default fit); Media-tile
      right-click **Edit…** + **Fit ▸** quick submenu; a compact Contain/Cover/
      Stretch bar in the Preview panel. *Caveat: cropped-video aspect is only
      exact when the crop matches the clip's aspect (the 16:9-locked cropper on
      16:9 footage); an off-aspect crop of off-aspect footage distorts slightly.*

- [ ] Video duration extraction works for new imports, but there's **no backfill**: a video imported before the V004 column (thumbnail already on disk) is skipped by `ensureForAllVideos` (`VideoThumbnailer.cpp:118`), so its duration badge stays hidden. Add a one-time re-probe.

### Tests
- [ ] Tests are OFF by default (`core/CMakeLists.txt:172`); only `LyricsDSL` and the `.craterheme` bundle round-trip are covered.
- [ ] No coverage for **Bible FTS search** or **MediaService import boundary-validation** — the two riskiest areas. Also untested: Song/Schedule/Projection/Output/Settings/Font services, the DB layer, migrations, and both importers.

### Housekeeping
- [ ] App migration numbering skips **V007** — files go V001–V006 then V008 (`core/CMakeLists.txt:155-164`, `core/src/db/migrations/app/`). Confirm the skip is intentional (reserved / removed) and not a lost migration.
- [ ] README porting-status table was stale; refreshed to match reality.
