import QtQuick
import QtQuick.Controls.Basic

// Media tab — full UX parity with the Electron media pane.
//
// Data flow (matches ARCHITECTURE.md §1/§4/§9):
//   • crater::MediaService owns the library (SQLite-backed, magic-byte
//     validation, size cap, file copy into AppDataLocation/media/).
//   • crater::ProjectionService owns `logoBgPath` (persisted via the kv
//     table — projection's choice, not a transient UI setting).
//   • This tab owns the transient view state via AppState (view mode,
//     grid density, sort field/order, batch selection).
//
// Behavior:
//   • Two import paths: (a) drag image / video files anywhere in the panel,
//     (b) click "+" to open the native OS file picker (via FileDialogService,
//     which uses QFileDialog — we still avoid the forbidden QtQuick.Dialogs
//     runtime module). Both paths funnel through MediaService.importPaths,
//     which validates by magic bytes regardless of extension.
//   • Action bar carries the count, view toggle (grid / list), grid-columns
//     selector (4–12), and sort menu (name / date / size / type, asc / desc).
//   • Grid view shows 16:9 thumbnails (real first-frame thumbs for videos,
//     populated asynchronously by VideoThumbnailer) with hover overlay,
//     type badge, batch-select checkbox, duration badge, and a Logo indicator
//     when set as background.
//   • List view shows a thumbnail + title row.
//   • Click a thumbnail to push it to Preview. Double-click / Enter goes Live.
//   • Ctrl/Cmd + click toggles batch selection; Shift + click selects a range.
//   • Right-click opens the context menu (Push Live, Rename, Set as Logo,
//     Add to Favorites, Add to Collection, Delete).
//
// Sidebar groups drive both type filter and an orthogonal favorites filter:
//   • "All Media" / "Images" / "Videos" set AppState.mediaTypeFilter via
//     AppState.setMediaGroup (the sidebar's onClicked routes through that
//     helper so the two slots stay in sync).
//   • "Favorites" leaves mediaTypeFilter untouched and applies a separate
//     filter inside filteredMedia — favorites can be a mix of images and
//     videos.
Item {
    id: root

    // Right-pane background — same `bgContent` as ScriptureTab / SongsTab
    // so the tab area reads consistently across the library.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.bgContent
        z: -1
    }


    readonly property string tabKey: "media"
    readonly property string query:  (AppState.searchText.media || "").toLowerCase()

    // Debounced shadow of query — coalesces fast typing into one
    // settle-then-filter per ~120ms. The dominant per-keystroke cost
    // here isn't the in-memory filter (cheap), it's that
    // onFilteredMediaChanged → pushPreviewFor → PreviewPanel's
    // MediaMonitor reloads an image or video for each preview swap as
    // the filter narrows. Debouncing the input collapses that to one
    // load per typing burst.
    property string _debouncedQuery: query
    Timer {
        id: queryDebounce
        interval: 120
        onTriggered: root._debouncedQuery = root.query
    }
    onQueryChanged: queryDebounce.restart()

    readonly property string typeFilter: AppState.mediaTypeFilter

    // Derived list after filtering, then sorting. The source is
    // MediaService.allMedia — a Q_PROPERTY that re-emits whenever the
    // backing table changes, so this binding stays live.
    readonly property var filteredMedia: {
        const all   = MediaService.allMedia
        // Debounced — see `_debouncedQuery` above. Reading `root.query`
        // here would trigger a PreviewPanel media reload per keystroke.
        const q     = root._debouncedQuery
        const tf    = root.typeFilter
        // Sidebar "Favorites" group is orthogonal to the type filter — it's
        // applied here rather than via mediaTypeFilter so a mixed-type
        // favorites set renders correctly.
        const onlyFavs = AppState.activeLibraryGroup.media === "favorites"
        let base    = []
        for (let i = 0; i < all.length; i++) {
            const m = all[i]
            if (!m) continue
            if (tf === "image" && m.type !== "image") continue
            if (tf === "video" && m.type !== "video") continue
            if (onlyFavs && !m.isFavorite) continue
            if (q.length > 0 && (m.title || "").toLowerCase().indexOf(q) === -1) continue
            base.push(m)
        }
        const f = AppState.mediaSortField
        const asc = AppState.mediaSortOrder === "asc"
        base.sort(function(a, b) {
            let cmp = 0
            if      (f === "name") cmp = a.title.localeCompare(b.title)
            else if (f === "type") cmp = a.type.localeCompare(b.type)
            else if (f === "date") cmp = (a.addedAt || 0) - (b.addedAt || 0)
            else                    cmp = a.id - b.id
            return asc ? cmp : -cmp
        })
        return base
    }

    readonly property int fluidIndex: AppState.libraryFluidIndex.media

    // ── Helpers ─────────────────────────────────────────────────────────

    function buildItemFromMedia(m) {
        if (!m) return null
        // PDFs become multi-page schedule items: one page entry per source
        // page so the existing page-advance machinery (Up/Down in Preview,
        // arrow nav in Live) drives PDF page navigation without any new
        // code path. Empty content keeps PreviewPanel's content-filter (it
        // strips zero-content pages from the page list) from showing
        // bordered rows — the cropper itself replaces that list for PDFs.
        // Images and videos keep the single-placeholder-page shape.
        let pages = [{ label: m.title, content: "" }]
        if (m.type === "pdf" && m.pageCount > 1) {
            pages = []
            for (let i = 0; i < m.pageCount; ++i) {
                pages.push({
                    label:   qsTr("Page %1").arg(i + 1),
                    content: ""
                })
            }
        }
        return {
            kind:      m.type,    // "image" | "video" | "pdf"
            title:     m.title,
            subtitle:  m.type === "pdf"
                           ? qsTr("PDF · %1 page%2")
                                 .arg(m.pageCount).arg(m.pageCount === 1 ? "" : "s")
                           : "",
            pages:     pages,
            mediaId:   m.id,
            mediaPath: m.path,
            pageCount: m.pageCount
        }
    }

    function mediaItemAt(idx) {
        if (idx < 0 || idx >= filteredMedia.length) return null
        return buildItemFromMedia(filteredMedia[idx])
    }

    function pushPreviewFor(idx) {
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        const item = mediaItemAt(idx)
        if (item) AppState.pushLibraryPreview(item)
        else      AppState.clearLibraryPreview()
    }

    function pushLiveFor(idx) {
        const item = mediaItemAt(idx)
        if (item) AppState.pushLibraryLive(item)
    }

    function addToScheduleFor(idx) {
        const item = mediaItemAt(idx)
        if (item) AppState.addItemToSchedule(item)
    }

    function isCurrentLogo(path) {
        return ProjectionService.logoBgPath
            && ProjectionService.logoBgPath === path
    }

    // Format an integer millisecond count as "m:ss" — used by the video
    // duration badge. Returns "" for non-positive values so the badge can
    // bind directly to durationMs and hide itself for un-probed items.
    function formatDuration(ms) {
        if (!ms || ms <= 0) return ""
        const totalSec = Math.floor(ms / 1000)
        const m = Math.floor(totalSec / 60)
        const s = totalSec % 60
        return m + ":" + (s < 10 ? "0" + s : "" + s)
    }

    // Drop handler — hand the raw URL list off to MediaService, which does
    // magic-byte validation, size capping, path normalization, and the
    // managed-directory file copy on a worker thread.
    function importPaths(paths) {
        if (!paths || paths.length === 0) return
        MediaService.importPaths(paths)
    }

    function toggleBatch(idx) {
        const cur = AppState.mediaBatchSelection.slice()
        const i   = cur.indexOf(idx)
        if (i >= 0) cur.splice(i, 1)
        else        cur.push(idx)
        AppState.mediaBatchSelection = cur
    }

    function selectRange(fromIdx, toIdx) {
        const lo = Math.min(fromIdx, toIdx)
        const hi = Math.max(fromIdx, toIdx)
        const cur = AppState.mediaBatchSelection.slice()
        for (let i = lo; i <= hi; i++) {
            if (cur.indexOf(i) === -1) cur.push(i)
        }
        AppState.mediaBatchSelection = cur
    }

    function batchDelete() {
        // Confirmation modal mirrors the per-row Delete in _mediaMenuItems
        // — friction proportional to consequence. Batch is the more
        // destructive of the two delete paths (N files, not 1), so it
        // gets the same "Are you sure?" gate the single-row case has
        // had since the start. Selection is snapshotted before opening
        // the modal so subsequent clicks (e.g. clearing the batch on a
        // background click while the dialog is open) don't shrink the
        // set we eventually delete.
        const selected = AppState.mediaBatchSelection.slice()
        const n = selected.length
        if (n === 0) return
        AppState.openModal("confirm", {
            title:       qsTr("Delete %1 item%2?").arg(n).arg(n === 1 ? "" : "s"),
            body:        qsTr("Remove %1 selected item%2 from your library? "
                            + "Files will also be deleted from managed media storage.")
                            .arg(n).arg(n === 1 ? "" : "s"),
            confirmText: qsTr("Delete"),
            onConfirm:   function() {
                for (let i = 0; i < selected.length; i++) {
                    const m = root.filteredMedia[selected[i]]
                    if (m) MediaService.remove(m.id)
                }
                AppState.clearMediaBatchSelection()
            }
        })
    }

    // Shared right-click menu builder — grid and list view both invoke it so
    // the two views stay in lockstep when items are added or reordered.
    // `isLogo` comes from the calling delegate (each view computes it slightly
    // differently — grid via cell._logo, list via listRow._logo).
    // Group order matches SongsTab and ScriptureTab: row-edit first
    // (Rename / Duplicate), then projection (Add to Schedule / Push to
    // Live / Set as Logo Background — Logo is a projection-configuration
    // action, lives with the projection group), then organization
    // (Favorites / Collection), then destructive (Delete) last where
    // slip-clicks are least likely.
    function _mediaMenuItems(media, isLogo, idx) {
        return [
            { label: qsTr("Rename"), iconName: "edit",
              action: function() {
                  AppState.openModal("naming", {
                      title:        qsTr("Rename media"),
                      placeholder:  qsTr("Title"),
                      confirmText:  qsTr("Save"),
                      initialValue: media.title,
                      onConfirm:    function(name) {
                          if (name && name.length > 0)
                              MediaService.rename(media.id, name)
                      }
                  })
              } },
            { label: qsTr("Duplicate"), iconName: "copy" },
            { separator: true },
            { label: qsTr("Add to Schedule"), iconName: "plus",
              action: function() { root.addToScheduleFor(idx) } },
            { label: qsTr("Push to Live"), iconName: "play",
              action: function() { root.pushLiveFor(idx) } },
            { label: qsTr("Set as Logo Background"), iconName: "sparkles",
              detail: isLogo ? "✓" : "",
              action: function() { ProjectionService.setLogoBg(media.path, media.type) } },
            { separator: true },
            { label: media.isFavorite
                    ? qsTr("Remove from Favorites")
                    : qsTr("Add to Favorites"),
              iconName: media.isFavorite ? "heart-off" : "heart",
              action: function() { MediaService.toggleFavorite(media.id) } },
            { label: qsTr("Add to Collection…"), iconName: "folder" },
            { separator: true },
            { label: qsTr("Delete"), iconName: "trash", destructive: true,
              action: function() {
                  AppState.openModal("confirm", {
                      title:       qsTr("Delete media?"),
                      body:        qsTr("Remove \"") + media.title + qsTr("\" from your library?"),
                      confirmText: qsTr("Delete"),
                      onConfirm:   function() { MediaService.remove(media.id) }
                  })
              } }
        ]
    }

    // Track filteredMedia.length across change-firings so we can detect
    // "grew" — that's our proxy for "an item was just added", which is the
    // signal we actually want to react to. This is more robust than tying
    // the snap to importFinished: it doesn't care about C++ signal ordering,
    // doesn't race with binding evaluation, and naturally handles every
    // path that adds rows (drag-drop, the + button, the empty-state CTA).
    //
    // First-mount sets `_initialized = true` without triggering a snap, so
    // existing rows on startup don't all flash a "new!" selection.
    property int  _prevFilteredMediaLength: 0
    property bool _initialized: false

    // Bounds-clamp fluid index when the list shrinks, AND snap to the most
    // recently added row whenever filteredMedia gains an item.
    onFilteredMediaChanged: {
        const n = filteredMedia.length

        if (n === 0) {
            if (fluidIndex !== -1) AppState.setLibraryFluid(tabKey, -1)
            _prevFilteredMediaLength = 0
            _initialized = true
            return
        }

        const grew = _initialized && n > _prevFilteredMediaLength
        _prevFilteredMediaLength = n
        _initialized = true

        if (grew) {
            // Find the item with the highest addedAt — that's the row the
            // worker just INSERTed (it stamps QDateTime::currentMSecsSinceEpoch).
            let newestIdx = 0
            let newestAt  = filteredMedia[0].addedAt || 0
            for (let i = 1; i < n; i++) {
                const at = filteredMedia[i].addedAt || 0
                if (at > newestAt) { newestAt = at; newestIdx = i }
            }
            const tgt = newestIdx
            AppState.setLibraryFluid(tabKey, tgt)
            if (AppState.tabKeys[AppState.activeTab] === tabKey)
                pushPreviewFor(tgt)
            // Defer scroll until the GridView/ListView have processed the
            // model rebind. onFilteredMediaChanged fires the same tick the
            // var property is reassigned; the views' own `model:` bindings
            // re-evaluate in a separate pass, so calling positionViewAtIndex
            // inline here can land on the stale (pre-import) delegate count
            // and silently no-op — leaving the new tile offscreen. callLater
            // (+ forceLayout) gives the views a tick to materialize the new
            // row before we scroll to it.
            Qt.callLater(function() {
                grid.forceLayout()
                listView.forceLayout()
                grid.positionViewAtIndex(tgt, GridView.Center)
                listView.positionViewAtIndex(tgt, ListView.Center)
            })
            return
        }

        const idx = (fluidIndex >= 0 && fluidIndex < n) ? fluidIndex : 0
        if (idx !== fluidIndex) AppState.setLibraryFluid(tabKey, idx)
        if (AppState.tabKeys[AppState.activeTab] === tabKey) pushPreviewFor(idx)
    }

    // Refresh preview when the operator switches into this tab.
    Connections {
        target: AppState
        function onActiveTabChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushPreviewFor(root.fluidIndex)
        }
    }

    // No importFinished hook needed for the snap-to-newest: the
    // onFilteredMediaChanged handler above detects model growth on its own.

    // ── Import affordance ───────────────────────────────────────────────
    // Two paths feed importPaths(): drag-drop on the DropArea below, and the
    // "+" / empty-state CTA which open the native OS file picker through
    // FileDialogService (QFileDialog under the hood — not the forbidden
    // QtQuick.Dialogs runtime module).
    function openImportDialog() {
        // The filter is purely a UX hint — MediaService still magic-byte
        // sniffs each file and rejects anything that doesn't match a known
        // image / video signature, so a user typing into the "all files"
        // dropdown can't break us.
        const filter = qsTr("Media (*.png *.jpg *.jpeg *.gif *.bmp *.webp "
                          + "*.mp4 *.mov *.m4v *.webm *.mkv *.avi)")
        const paths = FileDialogService.chooseOpenFiles(
            qsTr("Import media"), [filter])
        if (paths && paths.length > 0) root.importPaths(paths)
    }

    // ── Top action bar ──────────────────────────────────────────────────
    Rectangle {
        id: actionBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 32
        color: "transparent"

        // Center: count + batch indicator
        Row {
            anchors.centerIn: parent
            spacing: Theme.space.sm

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const n = root.filteredMedia.length
                    const noun = root.typeFilter === "image" ? qsTr("images")
                              : root.typeFilter === "video" ? qsTr("videos")
                                                            : qsTr("items")
                    return n.toLocaleString() + " " + noun
                         + (root.query.length > 0 ? qsTr(" matching") : "")
                }
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: AppState.mediaBatchSelection.length > 1
                text: "• " + AppState.mediaBatchSelection.length + " " + qsTr("selected")
                color: Theme.color.brand
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: AppState.mediaBatchSelection.length > 1
                width: 18; height: 18
                radius: 0
                color: clearBatchMa.containsMouse ? Theme.color.overlay : "transparent"
                AppIcon {
                    anchors.centerIn: parent
                    name: "x"; size: Theme.icon.xs
                    color: Theme.color.textTertiary
                }
                MouseArea {
                    id: clearBatchMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.clearMediaBatchSelection()
                }
            }
        }

        // ── Left side: + (import) button ─────────────────────────────────
        Rectangle {
            id: addBtn
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            width: 36; height: 22
            radius: 0
            color: addMa.containsMouse ? Theme.color.overlay : "transparent"
            border.color: Theme.color.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            AppIcon {
                anchors.centerIn: parent
                name: "plus"; size: Theme.icon.sm
                color: Theme.color.textSecondary
            }

            MouseArea {
                id: addMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openImportDialog()
            }
        }

        // ── Right side: view-mode, columns, sort, batch-delete ──────────
        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // Batch delete (only when selection > 1)
            Rectangle {
                visible: AppState.mediaBatchSelection.length > 1
                anchors.verticalCenter: parent.verticalCenter
                width: batchDelRow.implicitWidth + Theme.space.sm * 2
                height: 22
                radius: 0
                color: batchDelMa.containsMouse ? Theme.color.liveSubtle : "transparent"

                Row {
                    id: batchDelRow
                    anchors.centerIn: parent
                    spacing: 4
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "trash"; size: Theme.icon.xs
                        color: Theme.color.live
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Delete (") + AppState.mediaBatchSelection.length + ")"
                        color: Theme.color.live
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
                MouseArea {
                    id: batchDelMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.batchDelete()
                }
            }

            Rectangle {
                visible: AppState.mediaBatchSelection.length > 1
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: 14
                color: Theme.color.borderSubtle
            }

            // Grid view button
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 24; height: 22
                radius: 0
                color: gridViewMa.containsMouse ? Theme.color.overlay : "transparent"
                AppIcon {
                    anchors.centerIn: parent
                    name: "layout-grid"; size: Theme.icon.sm
                    color: AppState.mediaViewMode === "grid" ? Theme.color.brand : Theme.color.textSecondary
                }
                MouseArea {
                    id: gridViewMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.mediaViewMode = "grid"
                }
            }
            // List view button
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 24; height: 22
                radius: 0
                color: listViewMa.containsMouse ? Theme.color.overlay : "transparent"
                AppIcon {
                    anchors.centerIn: parent
                    name: "layout-list"; size: Theme.icon.sm
                    color: AppState.mediaViewMode === "list" ? Theme.color.brand : Theme.color.textSecondary
                }
                MouseArea {
                    id: listViewMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.mediaViewMode = "list"
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: 14
                color: Theme.color.borderSubtle
            }

            // Grid columns menu (grid mode only)
            Rectangle {
                id: colsBtn
                visible: AppState.mediaViewMode === "grid"
                anchors.verticalCenter: parent.verticalCenter
                width: colsRow.implicitWidth + Theme.space.sm * 2
                height: 22
                radius: 0
                color: colsMa.containsMouse ? Theme.color.overlay : "transparent"

                Row {
                    id: colsRow
                    anchors.centerIn: parent
                    spacing: 4
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "grid-3x3"; size: Theme.icon.sm
                        color: Theme.color.textSecondary
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: AppState.mediaGridColumns
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"; size: Theme.icon.tiny
                        color: Theme.color.textSecondary
                    }
                }
                MouseArea {
                    id: colsMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const items = []
                        const opts = [4, 6, 8, 10, 12]
                        for (let i = 0; i < opts.length; i++) {
                            const n = opts[i]
                            items.push({
                                label:    n + " " + qsTr("columns"),
                                detail:   AppState.mediaGridColumns === n ? "✓" : "",
                                action:   function() { AppState.mediaGridColumns = n }
                            })
                        }
                        AppState.openContextMenuAt(colsBtn,
                            colsBtn.width, colsBtn.height + 4,
                            items, { menuWidth: 160, dx: -160 })
                    }
                }
            }

            // Sort menu
            Rectangle {
                id: sortBtn
                anchors.verticalCenter: parent.verticalCenter
                width: sortRow.implicitWidth + Theme.space.sm * 2
                height: 22
                radius: 0
                color: sortMa.containsMouse ? Theme.color.overlay : "transparent"

                Row {
                    id: sortRow
                    anchors.centerIn: parent
                    spacing: 4
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: AppState.mediaSortOrder === "asc" ? "sort-asc" : "sort-desc"
                        size: Theme.icon.sm
                        color: Theme.color.textSecondary
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: AppState.mediaSortField
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.capitalization: Font.Capitalize
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"; size: Theme.icon.tiny
                        color: Theme.color.textSecondary
                    }
                }
                MouseArea {
                    id: sortMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const fields = [
                            { id: "name", label: qsTr("Name") },
                            { id: "date", label: qsTr("Date added") },
                            { id: "size", label: qsTr("File size") },
                            { id: "type", label: qsTr("Type") }
                        ]
                        const items = []
                        for (let i = 0; i < fields.length; i++) {
                            const f = fields[i]
                            items.push({
                                label:  f.label,
                                detail: AppState.mediaSortField === f.id
                                            ? (AppState.mediaSortOrder === "asc" ? "↑" : "↓")
                                            : "",
                                action: function() {
                                    if (AppState.mediaSortField === f.id) {
                                        AppState.mediaSortOrder =
                                            AppState.mediaSortOrder === "asc" ? "desc" : "asc"
                                    } else {
                                        AppState.mediaSortField = f.id
                                        AppState.mediaSortOrder = "asc"
                                    }
                                }
                            })
                        }
                        AppState.openContextMenuAt(sortBtn,
                            sortBtn.width, sortBtn.height + 4,
                            items, { menuWidth: 160, dx: -160 })
                    }
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }
    }

    // ── Drop area + content ─────────────────────────────────────────────
    DropArea {
        id: dropZone
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right

        property bool isOver: false

        onEntered: function(drag) {
            isOver = drag.hasUrls
        }
        onExited: isOver = false
        onDropped: function(drop) {
            isOver = false
            if (!drop.hasUrls) return
            const paths = []
            for (let i = 0; i < drop.urls.length; i++) {
                paths.push(drop.urls[i].toString())
            }
            root.importPaths(paths)
            drop.accept()
        }

        // Drop overlay
        Rectangle {
            anchors.fill: parent
            anchors.margins: Theme.space.sm
            visible: dropZone.isOver
            z: 100
            radius: 0
            color: Qt.rgba(Theme.color.brand.r, Theme.color.brand.g, Theme.color.brand.b, 0.18)
            border.color: Theme.color.brand
            border.width: 2

            Column {
                anchors.centerIn: parent
                spacing: Theme.space.sm
                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "cloud-upload"; size: Theme.icon.xxl
                    color: Theme.color.brand
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Drop files here")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.titleSize
                    font.weight: Theme.font.weightSemiBold
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Images and videos will be imported")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
        }

        // ── Empty states ────────────────────────────────────────────────
        EmptyState {
            anchors.fill: parent
            visible: MediaService.allMedia.length === 0
            iconName: "image-off"
            title: qsTr("No media yet")
            body: qsTr("Drag image or video files here, or click + to import them")
        }

        Item {
            anchors.fill: parent
            visible: MediaService.allMedia.length === 0

            PrimaryButton {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.verticalCenter
                anchors.topMargin: 72
                variant: "brand"
                iconName: "upload"
                text: qsTr("Import media")
                onClicked: root.openImportDialog()
            }
        }

        EmptyState {
            anchors.fill: parent
            visible: MediaService.allMedia.length > 0 && root.filteredMedia.length === 0
            iconName: "search-x"
            title: qsTr("No media found")
            body: root.query.length > 0
                  ? qsTr("No items match \"") + root.query + "\""
                  : qsTr("Try a different filter")
        }

        // ── Grid view ───────────────────────────────────────────────────
        GridView {
            id: grid
            ScrollBar.vertical: AppScrollBar {}
            anchors.fill: parent
            anchors.margins: Theme.space.sm
            anchors.rightMargin: 0   // run to the panel edge; the cell math reserves the bar's lane
            clip: true
            cacheBuffer: 600
            visible: AppState.mediaViewMode === "grid" && root.filteredMedia.length > 0
            currentIndex: root.fluidIndex
            model: root.filteredMedia
            cellWidth:  Math.max(80, Math.floor((width - Theme.size.scrollBar) / Math.max(1, AppState.mediaGridColumns)))
            cellHeight: Math.floor(cellWidth * 9.0 / 16.0) + 4

            delegate: Item {
                id: cell
                width: grid.cellWidth
                height: grid.cellHeight

                // _selected reads directly from fluidIndex (the canonical
                // selection in AppState) rather than `grid.currentIndex`.
                // Reason: GridView's currentIndex binding to fluidIndex can
                // be silently broken by Qt's internal handling — when the
                // `filteredMedia` property re-emits (which it does on any of
                // its 6+ dependency changes, even when content is identical),
                // GridView treats it as a model rebind and writes to
                // currentIndex internally. That assignment severs the
                // property binding, and from then on the visible selection
                // drifts away from fluidIndex (typically resetting to 0).
                // Reading fluidIndex directly is binding-rebind-safe.
                readonly property bool _selected: index === root.fluidIndex
                readonly property bool _batch:    AppState.mediaBatchSelection.indexOf(index) !== -1
                // True while the library pane owns keyboard focus. When focus
                // moves to Schedule / Preview / Live, the selected-tile border
                // mutes to a neutral borderStrong. The _batch border stays
                // vivid regardless of focus — multi-select is an explicit
                // operator commitment that should always read.
                readonly property bool _paneFocused: AppState.activeFocusPanel === "library"
                // LIVE compares against ProjectionService.currentItem — the
                // canonical "what's on the projector right now" reference.
                // The previous predicate read libraryPreviewItem, which is
                // the *preview* slot and changes on every selection, so any
                // selected tile inherited LIVE once any media had been
                // pushed live in this session. libraryLiveActive still
                // gates the badge so a media item driven from the schedule
                // (where the live source isn't the library) doesn't claim
                // a LIVE chip on the media tab.
                readonly property bool _live:
                    AppState.libraryLiveActive
                    && ProjectionService.currentItem
                    && ProjectionService.currentItem.mediaId === modelData.id
                // PREVIEW: this tile is the one currently shown in the
                // Preview pane. Suppressed when _live is also true so the
                // two badges never stack — LIVE outranks PREVIEW visually
                // and semantically (live is the destination state).
                readonly property bool _preview:
                    !_live
                    && AppState.libraryPreviewItem
                    && AppState.libraryPreviewItem.mediaId === modelData.id
                readonly property bool _logo:     root.isCurrentLogo(modelData.path)

                Rectangle {
                    id: thumb
                    anchors.fill: parent
                    anchors.margins: 3
                    radius: 0
                    color: "#0d0d12"
                    // z:1 lifts thumb (and its nested interactive children
                    // — most importantly the batch-select checkbox's
                    // MouseArea) above cellMa, which is a sibling declared
                    // later in this delegate and therefore wins hit testing
                    // by default. Without this, clicks on the checkbox
                    // were swallowed by cellMa's plain-click branch
                    // (fluid-focus + pushPreview) and never reached
                    // toggleBatch — multi-select was effectively dead via
                    // the checkbox. Ctrl/Shift+click on the tile still
                    // worked because that path lives inside cellMa itself.
                    // Non-MouseArea content inside thumb (the image, type
                    // badge, state pill, hover scrim) doesn't capture
                    // events, so plain clicks still fall through to cellMa.
                    z: 1
                    // Border priority: batch (always vivid brand) > selected
                    // (brand-pressed when pane focused, borderStrong when not)
                    // > hover > none. The selected border was previously
                    // `Theme.color.preview` (gold) — a vestige from when media
                    // selection was visualised in the Preview channel's palette.
                    // Re-pointed to brand so all library tabs share the same
                    // selection identity, with focus-gating to match.
                    border.color: cell._batch ? Theme.color.brand
                                : cell._selected
                                  ? (cell._paneFocused ? Theme.color.brandPressed
                                                       : Theme.color.borderStrong)
                                : cellMa.containsMouse ? Theme.color.borderStrong
                                                       : "transparent"
                    border.width: 2

                    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                    // Image preview (best-effort — Qt Image handles png/jpg/etc).
                    // Gate `source` on type === "image": `visible: false` only
                    // hides the render, it does NOT cancel the loader, so a
                    // video row's .mp4 path was being fed to QImageReader and
                    // logging "Unsupported image format" repeatedly.
                    Image {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: modelData.type === "image"
                        source: modelData.type === "image"
                              ? "file:///" + modelData.path
                              : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        sourceSize.width: 320
                        sourceSize.height: 180
                    }
                    // Video thumbnail. VideoThumbnailer renders the first
                    // frame async after import; the icon fallback below
                    // shows while the thumb file doesn't exist yet (or
                    // never will, for codec-broken videos).
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: modelData.type === "video"
                        color: "#13131a"

                        AppIcon {
                            anchors.centerIn: parent
                            visible: videoThumb.status !== Image.Ready
                            name: "video"; size: Theme.icon.xl
                            color: Theme.color.textTertiary
                        }

                        Image {
                            id: videoThumb
                            anchors.fill: parent
                            // `readyCounter` makes this binding re-run after
                            // each thumb extraction so the placeholder flips
                            // to the real frame without a tab refresh.
                            source: {
                                const _ = VideoThumbnailer.readyCounter
                                const p = VideoThumbnailer.thumbnailPathFor(modelData.id)
                                return p.length > 0 ? "file:///" + p : ""
                            }
                            visible: status === Image.Ready
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            sourceSize.width: 320
                            sourceSize.height: 180
                        }
                    }

                    // PDF thumbnail. Pulls the first page through the same
                    // image://pdfpage provider used by the live render path,
                    // so the cache primed by viewing the PDF in Preview is
                    // re-hit when the operator returns to the media grid.
                    // No separate thumbnail file on disk — pdfium re-renders
                    // at thumbnail size in ~10 ms, well under the framerate
                    // budget for a cold tile.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: modelData.type === "pdf"
                        color: "#13131a"

                        AppIcon {
                            anchors.centerIn: parent
                            visible: pdfThumb.status !== Image.Ready
                            name: "file-text"; size: Theme.icon.xl
                            color: Theme.color.textTertiary
                        }

                        Image {
                            id: pdfThumb
                            anchors.fill: parent
                            source: modelData.type === "pdf"
                                  ? "image://pdfpage/" + modelData.id + "?page=0"
                                  : ""
                            visible: status === Image.Ready
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            sourceSize.width: 320
                            sourceSize.height: 180
                        }
                    }

                    // Type badge (top-right)
                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 4
                        width: 18; height: 18
                        radius: 0
                        color: "#000000bb"
                        AppIcon {
                            anchors.centerIn: parent
                            name: modelData.type === "video" ? "video"
                                : modelData.type === "pdf"   ? "file-text"
                                                             : "image"
                            size: Theme.icon.xs
                            color: "#ffffff"
                        }
                    }

                    // Logo badge
                    Rectangle {
                        visible: cell._logo
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 4
                        anchors.rightMargin: 26
                        width: 18; height: 18
                        radius: 0
                        color: Theme.color.success
                        AppIcon {
                            anchors.centerIn: parent
                            name: "sparkles"; size: Theme.icon.xs
                            color: "#ffffff"
                        }
                    }

                    // Batch-select checkbox (top-left, shows on hover or when batch active)
                    Rectangle {
                        visible: cellMa.containsMouse || cell._batch
                              || AppState.mediaBatchSelection.length > 0
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 4
                        width: 18; height: 18
                        radius: 0
                        color: cell._batch ? Theme.color.brand : "#000000bb"
                        border.color: cell._batch ? Theme.color.brand : "#ffffff44"
                        border.width: 1
                        AppIcon {
                            anchors.centerIn: parent
                            visible: cell._batch
                            name: "check"; size: Theme.icon.xs
                            color: "#ffffff"
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleBatch(index)
                        }
                    }

                    // State pill (bottom-left). Renders as LIVE (live-red)
                    // when this tile is what's currently on the projector,
                    // PREVIEW (bright brand-cyan) when it's only staged in
                    // the Preview pane. Mutually exclusive — see _preview's
                    // !_live gate above. One Rectangle for both states
                    // keeps the visual position stable as the operator
                    // promotes preview → live.
                    //
                    // z:2 so the pill sits ABOVE the hover-title scrim
                    // declared lower in this delegate — without it, the
                    // scrim's title text was painting over the pill on
                    // hover. id is exposed so the hover title's anchors
                    // can stop at this pill's right edge.
                    Rectangle {
                        id: statePill
                        visible: cell._live || cell._preview
                        z: 2
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.margins: 4
                        width: statePillLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 0
                        color: cell._live ? Theme.color.live : Theme.color.brand

                        Text {
                            id: statePillLabel
                            anchors.centerIn: parent
                            text: cell._live ? qsTr("LIVE") : qsTr("PREVIEW")
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.5
                        }
                    }

                    // Video duration badge (bottom-right). Only shown once
                    // VideoThumbnailer has probed the clip — until then
                    // durationMs is 0 and the badge stays hidden.
                    // z:2 + id mirror the state pill so the hover-title
                    // scrim never paints over the duration text.
                    Rectangle {
                        id: durBadge
                        visible: modelData.type === "video" && modelData.durationMs > 0
                        z: 2
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.margins: 4
                        width: durLabel.implicitWidth + 8
                        height: 16
                        radius: 0
                        color: "#000000b8"

                        Text {
                            id: durLabel
                            anchors.centerIn: parent
                            text: root.formatDuration(modelData.durationMs)
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 12
                            font.weight: Theme.font.weightMedium
                        }
                    }

                    // Hover title scrim. Vertical gradient (transparent
                    // top → opaque dark bottom) reads as a polished
                    // photographic vignette rather than a flat band, and
                    // the deeper bottom stop gives ~AAA contrast against
                    // even bright video frames (water, snow, sky) that
                    // used to wash out the previous flat "#000000aa".
                    //
                    // The title text gets a per-glyph 1 px black drop
                    // shadow (Text.Raised + styleColor) so legibility
                    // holds even at the transparent top of the scrim.
                    // Same trick ThemesTab uses for the name chip over
                    // theme tiles.
                    //
                    // anchors.left / right adapt to whichever pills are
                    // present so the title can never overlap them —
                    // statePill on the left, durBadge on the right.
                    Rectangle {
                        visible: cellMa.containsMouse
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 2
                        height: 26
                        radius: 0
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 0.45; color: "#00000080" }
                            GradientStop { position: 1.0; color: "#000000e6" }
                        }

                        Text {
                            anchors.left: statePill.visible ? statePill.right : parent.left
                            anchors.right: durBadge.visible ? durBadge.left : parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            text: modelData.title
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 12
                            font.weight: Theme.font.weightMedium
                            elide: Text.ElideRight
                            style: Text.Raised
                            styleColor: "#000000"
                        }
                    }
                }

                MouseArea {
                    id: cellMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton

                    onClicked: function(mouse) {
                        AppState.setLibraryFluid(root.tabKey, index)
                        // Row click claims arrow-key focus for the library —
                        // see ScriptureTab._focus for rationale. Covers the
                        // right-click / shift / ctrl branches too; any one
                        // of them is a user-initiated row interaction.
                        AppState.setActiveFocus("library")
                        if (mouse.button === Qt.RightButton) {
                            root.pushPreviewFor(index)
                            AppState.openContextMenuAt(this, mouse.x, mouse.y,
                                root._mediaMenuItems(modelData, cell._logo, index))
                        } else if (mouse.modifiers & Qt.ShiftModifier
                                  && AppState.mediaBatchSelection.length > 0) {
                            const last = AppState.mediaBatchSelection[AppState.mediaBatchSelection.length - 1]
                            root.selectRange(last, index)
                        } else if (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
                            root.toggleBatch(index)
                        } else {
                            // plain click: clear batch, set fluid focus, push to preview
                            if (AppState.mediaBatchSelection.length > 0)
                                AppState.clearMediaBatchSelection()
                            root.pushPreviewFor(index)
                        }
                    }
                    onDoubleClicked: {
                        AppState.setLibraryFluid(root.tabKey, index)
                        AppState.setActiveFocus("library")
                        root.pushLiveFor(index)
                    }
                }
            }
        }

        // ── List view ───────────────────────────────────────────────────
        ListView {
            id: listView
            ScrollBar.vertical: AppScrollBar {}
            anchors.fill: parent
            anchors.margins: Theme.space.sm
            anchors.rightMargin: 0   // run to the panel edge; delegate reserves the bar's lane
            clip: true
            cacheBuffer: 400
            visible: AppState.mediaViewMode === "list" && root.filteredMedia.length > 0
            model: root.filteredMedia
            spacing: 2
            currentIndex: root.fluidIndex

            delegate: Item {
                id: listRow
                width: listView.width - Theme.size.scrollBar
                height: 48

                // Same binding-rebind-safe pattern as the grid cell — read
                // fluidIndex directly rather than listView.currentIndex, which
                // can drift to 0 when ListView's internal handling writes to
                // currentIndex during a model re-emit.
                readonly property bool _selected: index === root.fluidIndex
                readonly property bool _batch:    AppState.mediaBatchSelection.indexOf(index) !== -1
                // Same focus-gating as the grid cell — selected row mutes
                // when library pane loses focus.
                readonly property bool _paneFocused: AppState.activeFocusPanel === "library"
                // Same fix as the grid delegate — see the comment there.
                // _live compares against ProjectionService.currentItem so
                // the badge tracks the actual live item, not whichever
                // tile is currently in the preview slot.
                readonly property bool _live:
                    AppState.libraryLiveActive
                    && ProjectionService.currentItem
                    && ProjectionService.currentItem.mediaId === modelData.id
                readonly property bool _preview:
                    !_live
                    && AppState.libraryPreviewItem
                    && AppState.libraryPreviewItem.mediaId === modelData.id
                readonly property bool _logo:     root.isCurrentLogo(modelData.path)

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.sm
                    anchors.rightMargin: Theme.space.sm
                    radius: 0
                    // List row coloring: batch (always vivid) > selected (brand
                    // when focused, neutral when not) > hover > transparent.
                    // Previously selected used `previewSubtle` + `preview` (gold)
                    // — re-pointed to brand family so all library tabs share
                    // the same selection identity.
                    color: listRow._batch    ? Theme.color.brandSubtle
                         : listRow._selected
                           ? (listRow._paneFocused ? Theme.color.brandSubtle
                                                   : Theme.color.selectionUnfocused)
                         : rowMa.containsMouse ? Theme.color.elevated
                                               : "transparent"
                    border.color: listRow._batch ? Theme.color.brand
                                : listRow._selected
                                  ? (listRow._paneFocused ? Theme.color.brandPressed
                                                          : Theme.color.borderStrong)
                                : "transparent"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

                // Batch-checkbox (visible on hover or while batch is active)
                // z:1 lifts this above rowMa (the row-wide click handler
                // declared later in this delegate). Without it, clicks on
                // the checkbox were swallowed by rowMa's plain-click branch
                // and toggleBatch never fired. Same bug pattern as the
                // grid delegate's thumb.z fix.
                Rectangle {
                    id: rowCheckbox
                    z: 1
                    visible: rowMa.containsMouse || listRow._batch
                          || AppState.mediaBatchSelection.length > 0
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16
                    radius: 0
                    color: listRow._batch ? Theme.color.brand : "transparent"
                    border.color: listRow._batch ? Theme.color.brand : Theme.color.borderStrong
                    border.width: 1
                    AppIcon {
                        anchors.centerIn: parent
                        visible: listRow._batch
                        name: "check"; size: Theme.icon.xs
                        color: "#ffffff"
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleBatch(index)
                    }
                }

                // Thumbnail
                Rectangle {
                    id: rowThumb
                    anchors.left: rowCheckbox.visible ? rowCheckbox.right : parent.left
                    anchors.leftMargin: rowCheckbox.visible ? Theme.space.sm : Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    width: 56; height: 32
                    radius: 0
                    color: "#0d0d12"
                    clip: true

                    Image {
                        anchors.fill: parent
                        visible: modelData.type === "image"
                        // Same gate as the grid Image — see the comment there.
                        source: modelData.type === "image"
                              ? "file:///" + modelData.path
                              : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 120
                        sourceSize.height: 70
                    }
                    // Video: thumbnail when one exists, icon fallback otherwise.
                    Image {
                        id: rowVideoThumb
                        anchors.fill: parent
                        visible: modelData.type === "video" && status === Image.Ready
                        source: {
                            if (modelData.type !== "video") return ""
                            const _ = VideoThumbnailer.readyCounter
                            const p = VideoThumbnailer.thumbnailPathFor(modelData.id)
                            return p.length > 0 ? "file:///" + p : ""
                        }
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 120
                        sourceSize.height: 70
                    }
                    AppIcon {
                        anchors.centerIn: parent
                        visible: modelData.type === "video"
                              && rowVideoThumb.status !== Image.Ready
                        name: "video"; size: Theme.icon.lg
                        color: Theme.color.textTertiary
                    }

                    // PDF: page-0 thumbnail through the same provider used
                    // by Preview/Live so the QML image cache hits across
                    // surfaces (open in MediaTab, hop to Preview, swap back
                    // to MediaTab → no re-rasterize).
                    Image {
                        id: rowPdfThumb
                        anchors.fill: parent
                        visible: modelData.type === "pdf" && status === Image.Ready
                        source: modelData.type === "pdf"
                              ? "image://pdfpage/" + modelData.id + "?page=0"
                              : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 120
                        sourceSize.height: 70
                    }
                    AppIcon {
                        anchors.centerIn: parent
                        visible: modelData.type === "pdf"
                              && rowPdfThumb.status !== Image.Ready
                        name: "file-text"; size: Theme.icon.lg
                        color: Theme.color.textTertiary
                    }
                }

                Column {
                    anchors.left: rowThumb.right
                    anchors.leftMargin: Theme.space.md
                    anchors.right: rowRight.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text: modelData.title
                        color: listRow._selected ? Theme.color.textPrimary : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    Row {
                        spacing: Theme.space.sm
                        Text {
                            text: modelData.type
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.capitalization: Font.Capitalize
                        }
                        Row {
                            visible: listRow._logo
                            spacing: 2
                            AppIcon { name: "sparkles"; size: Theme.icon.xs; color: Theme.color.success }
                            Text {
                                text: qsTr("Logo")
                                color: Theme.color.success
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }
                        }
                    }
                }

                Row {
                    id: rowRight
                    // z:1 lifts the right-side cluster (LIVE/PREVIEW pill,
                    // hover favorite-toggle star) above rowMa so the
                    // favorite star's MouseArea can actually receive
                    // clicks — same z-order fix as rowCheckbox above.
                    z: 1
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.xs

                    // State pill — LIVE (live-red) or PREVIEW (brand-cyan).
                    // Single Rectangle for both states so the row's right-
                    // hand chrome stays positionally stable as preview →
                    // live promotes. Mutually exclusive via _preview's
                    // !_live gate.
                    Rectangle {
                        visible: listRow._live || listRow._preview
                        anchors.verticalCenter: parent.verticalCenter
                        width: rowStateLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 0
                        color: listRow._live ? Theme.color.live : Theme.color.brand
                        Text {
                            id: rowStateLabel
                            anchors.centerIn: parent
                            text: listRow._live ? qsTr("LIVE") : qsTr("PREVIEW")
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                        }
                    }
                    Rectangle {
                        visible: rowMa.containsMouse && !modelData.isFavorite
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18
                        radius: 0
                        color: favMa.containsMouse ? Theme.color.overlay : "transparent"
                        AppIcon {
                            anchors.centerIn: parent
                            name: "star"; size: Theme.icon.xs
                            color: Theme.color.textTertiary
                        }
                        MouseArea {
                            id: favMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: MediaService.toggleFavorite(modelData.id)
                        }
                    }
                    AppIcon {
                        visible: modelData.isFavorite
                        anchors.verticalCenter: parent.verticalCenter
                        name: "heart"; size: Theme.icon.sm
                        color: Theme.color.brand
                    }
                }

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton

                    onClicked: function(mouse) {
                        AppState.setLibraryFluid(root.tabKey, index)
                        // Library focus claim — see grid view above for
                        // rationale.
                        AppState.setActiveFocus("library")
                        if (mouse.button === Qt.RightButton) {
                            root.pushPreviewFor(index)
                            AppState.openContextMenuAt(this, mouse.x, mouse.y,
                                root._mediaMenuItems(modelData, listRow._logo, index))
                        } else if (mouse.modifiers & Qt.ShiftModifier
                                  && AppState.mediaBatchSelection.length > 0) {
                            const last = AppState.mediaBatchSelection[AppState.mediaBatchSelection.length - 1]
                            root.selectRange(last, index)
                        } else if (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
                            root.toggleBatch(index)
                        } else {
                            if (AppState.mediaBatchSelection.length > 0)
                                AppState.clearMediaBatchSelection()
                            root.pushPreviewFor(index)
                        }
                    }
                    onDoubleClicked: {
                        AppState.setLibraryFluid(root.tabKey, index)
                        AppState.setActiveFocus("library")
                        root.pushLiveFor(index)
                    }
                }
            }
        }
    }

    // ── Keyboard navigation routed from TabSearchBar ────────────────────
    // Grid view: Up/Down step by `mediaGridColumns` (one row at a time) and
    // Left/Right step by one tile (sequential, so Left at column 0 walks
    // back into the previous row's last tile). List view: Up/Down step by 1;
    // Left/Right are no-ops (gated below — list rows are one-dimensional).
    Connections {
        target: AppState
        function onLibraryNavigateDown() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.filteredMedia.length === 0) return
            const step = AppState.mediaViewMode === "grid"
                       ? Math.max(1, AppState.mediaGridColumns) : 1
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + step,
                                  root.filteredMedia.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryNavigateUp() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.filteredMedia.length === 0) return
            const step = AppState.mediaViewMode === "grid"
                       ? Math.max(1, AppState.mediaGridColumns) : 1
            const next = Math.max(root.fluidIndex - step, 0)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryNavigateLeft() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (AppState.mediaViewMode !== "grid") return
            if (root.filteredMedia.length === 0) return
            const next = Math.max((root.fluidIndex < 0 ? 0 : root.fluidIndex) - 1, 0)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryNavigateRight() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (AppState.mediaViewMode !== "grid") return
            if (root.filteredMedia.length === 0) return
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + 1,
                                  root.filteredMedia.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushLiveFor(root.fluidIndex)
        }
        function onLibraryAddToSchedule() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.addToScheduleFor(root.fluidIndex)
        }
    }
}
