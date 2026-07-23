# Crater (Qt) — Remaining Work

Punch-list of what's left before v1 / v1.1. Crater is essentially
feature-complete for a v1 core (Bible, Songs, Themes + editor, Schedule,
Media, Fonts, Projection + transitions, multi-monitor routing, NDI, and the
operator console are all done). What remains splits into: a couple of
genuinely-unbuilt features, a set of settings toggles that render but do
nothing yet ("Soon"), v1.1-deferred items, and tuning/loose ends.

Status legend: 🔴 unbuilt feature · 🟡 UI exists but inert · 🔵 v1.1 deferred · 🟢 works, rough edge

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
- [ ] **Tier 2/3 extra themes** (backlog, taste-driven — build on request):
      *Tier 2 established palettes* — Nord, Solarized Dark/Light, Gruvbox,
      Dracula. *Tier 3 brand-hue variants* — Royal Purple, Amber/Gold,
      Ecclesial Blue (keep the neutral dark stack, swap only the brand hue).
      Prereq for Tier 3 to be cheap: add a base-palette + per-theme override
      layer so a variant is ~5 tokens instead of a full ~45-token copy;
      today every palette spells out all 45 tokens (no inheritance).
- [ ] **Language** switcher, `:143-156` — no i18n catalog.

### Scripture (`app/qml/dialogs/settings/ScriptureSection.qml`)
- [ ] **Highlight current verse**, `:76-100` — no verse-rendering site to highlight.
- [ ] **Show book:chapter in footer**, `:103-127` — no slide-footer rendering.

### Song (`app/qml/dialogs/settings/SongSection.qml`)
- [ ] **Default theme** picker, `:55-79` — needs a theme popover (shared `SelectChip` dropdown is itself a "future wire-up").
- [ ] **Auto-advance slides**, `:84-108` — no timer infrastructure.

### NDI (`app/qml/dialogs/settings/NdiSection.qml`)
- [ ] **Quality / format** selector, `:204-227` — fixed to Native BGRA for v1.
- [ ] **Include audio**, `:231-254` — no audio tap.

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

## 🟢 Tuning / loose ends (works, but rough)

### NDI
- [ ] On-demand render mode (latest commit `d08c17c`) ships **off-by-default** (`app/src/NdiRenderer.cpp:349`, toggle `NdiSection.qml:350`) — finish validating, then decide default.
- [ ] Canvas size **hardcoded 1920×1080** (`NdiRenderer.cpp:32-33`) — the headless path won't render themes whose canvas isn't 1080p. Parameterize.
- [ ] Two capture paths advertise **different frame rates** — legacy `30000/1001` (`NdiService.cpp:516`) vs headless `60000/1001` (`NdiService.cpp:576`). Reconcile.

### Search quality — Scripture & Songs (greatly improve)
Both searches work but are minimal: Scripture is an FTS5 **trigram** match over
`verses.text` (`BibleService::search`, dual-mode reference/FTS in
`ScriptureTab.qml`), Songs is FTS5 over title+author+lyrics
(`SongService::search`). Neither ranks, highlights, or scopes usefully. Raise
both to a "great search" bar:
- [ ] **Ranked results.** Order by `bm25()` (both FTS tables already support it —
      `SearchHit.score` exists but isn't used to sort) instead of table order;
      tune column weights (title/author > lyrics; keep verse ordering as a
      tie-break).
- [ ] **Match highlighting.** Return FTS `snippet()`/`highlight()` spans and bold
      the matched terms in the result rows — and, for Scripture, on the projected
      slide when "Highlight current verse" lands (`ScriptureSection.qml:76-100`).
- [ ] **Query operators.** Support quoted phrases, `AND`/`OR`/`NOT`, and prefix
      (`word*`); today the raw string is passed straight to FTS so a stray quote
      or operator char can error. Sanitize + expose the operators intentionally.
- [ ] **Scoping filters.** Scripture: book / testament / translation (search all
      translations at once, not just the active one). Songs: field-scoped
      (title-only vs lyrics) + filter by collection/theme once collections land.
- [ ] **Typo tolerance** for Songs (trigram or edit-distance fallback when FTS
      returns nothing) so a misspelled title still surfaces.
- [ ] **Result affordances.** Show the matched lyric section / verse snippet in
      the row, add sort options, and keep a short recent-search history.

### Media
- [ ] Video duration extraction works for new imports, but there's **no backfill**: a video imported before the V004 column (thumbnail already on disk) is skipped by `ensureForAllVideos` (`VideoThumbnailer.cpp:118`), so its duration badge stays hidden. Add a one-time re-probe.

### Tests
- [ ] Tests are OFF by default (`core/CMakeLists.txt:172`); only `LyricsDSL` and the `.craterheme` bundle round-trip are covered.
- [ ] No coverage for **Bible FTS search** or **MediaService import boundary-validation** — the two riskiest areas. Also untested: Song/Schedule/Projection/Output/Settings/Font services, the DB layer, migrations, and both importers.

### Housekeeping
- [ ] App migration numbering skips **V007** — files go V001–V006 then V008 (`core/CMakeLists.txt:155-164`, `core/src/db/migrations/app/`). Confirm the skip is intentional (reserved / removed) and not a lost migration.
- [ ] README porting-status table was stale; refreshed to match reality.
