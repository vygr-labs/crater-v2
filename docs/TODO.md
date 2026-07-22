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
- [ ] **Upload the two DBs to the `data-v1` GitHub release** so CI's download fallback works on a cold cache (currently only `bibles.sqlite` is there). SHA-256s are baked into the release scripts: dictionary `27890d55…`, bible `8934fdf6…`.
- [ ] Dedicated `strongs` theme kind + per-output pinning (currently reuses the scripture theme). Optional.
- [ ] Minor: Dictionary and Reader share one search box (keyword vs reference), so toggling views leaves stale text.

### Song collections
No `CollectionService` exists.
- [ ] `CollectionService` (create / rename / duplicate / destroy).
- [ ] "My Collections" sidebar group is hardcoded to `count: 0`, `subgroups: []` (`LibrarySidebar.qml:41-58`).
- [ ] Bottom action strip is `visible: false` pending the service (`LibrarySidebar.qml:286-293`).
- [ ] "+" new-collection button is a no-op `onClicked: {}` (`LibrarySidebar.qml:334-337`); wire to `AppState.openModal("naming", …)`.
- [ ] Gear (Rename/Duplicate/Edit/Delete) button is a no-op `onClicked: {}` (`LibrarySidebar.qml:359-361`); open a `PopoverMenu`.

---

## 🟡 Settings that render but do nothing (disabled + "Soon" badge)

Each needs backing infrastructure, not just flipping `enabled: true`.

### Appearance (`app/qml/dialogs/settings/AppearanceSection.qml`)
- [ ] Theme **Mode** (Light / Dark / Auto), `:57-77` — no light palette exists yet.
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

### Media
- [ ] Video duration extraction works for new imports, but there's **no backfill**: a video imported before the V004 column (thumbnail already on disk) is skipped by `ensureForAllVideos` (`VideoThumbnailer.cpp:118`), so its duration badge stays hidden. Add a one-time re-probe.

### Tests
- [ ] Tests are OFF by default (`core/CMakeLists.txt:172`); only `LyricsDSL` and the `.craterheme` bundle round-trip are covered.
- [ ] No coverage for **Bible FTS search** or **MediaService import boundary-validation** — the two riskiest areas. Also untested: Song/Schedule/Projection/Output/Settings/Font services, the DB layer, migrations, and both importers.

### Housekeeping
- [ ] App migration numbering skips **V007** — files go V001–V006 then V008 (`core/CMakeLists.txt:155-164`, `core/src/db/migrations/app/`). Confirm the skip is intentional (reserved / removed) and not a lost migration.
- [ ] README porting-status table was stale; refreshed to match reality.
