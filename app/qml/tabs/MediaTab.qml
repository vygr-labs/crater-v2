import QtQuick

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
//   • Drag image / video files anywhere in the panel to import them — this is
//     the only import path. We deliberately do NOT use QtQuick.Dialogs: the
//     architecture keeps the executable lean and reserves file I/O for
//     crater-core services. A future MediaService method can expose a native
//     file picker; until then the "+" button pulses the drop overlay.
//   • Action bar carries the count, view toggle (grid / list), grid-columns
//     selector (4–12), and sort menu (name / date / size / type, asc / desc).
//   • Grid view shows 16:9 thumbnails with hover overlay, type badge,
//     batch-select checkbox, and a Logo indicator when set as background.
//   • List view shows a thumbnail + title row.
//   • Click a thumbnail to push it to Preview. Double-click / Enter goes Live.
//   • Ctrl/Cmd + click toggles batch selection; Shift + click selects a range.
//   • Right-click opens the context menu (Push Live, Edit, Set as Logo,
//     Add to Favorites, Add to Collection, Delete).
//
// Type filter (images / videos) is driven by the sidebar group ("all-media",
// "images", "videos" — synthesized below). The sidebar currently only shows
// "All Media" so all types render together; switching the group binding is a
// one-line follow-up when the sidebar gains the sub-rows.
Item {
    id: root

    readonly property string tabKey: "media"
    readonly property string query:  (AppState.searchText.media || "").toLowerCase()
    readonly property string typeFilter: AppState.mediaTypeFilter

    // Derived list after filtering, then sorting. The source is
    // MediaService.allMedia — a Q_PROPERTY that re-emits whenever the
    // backing table changes, so this binding stays live.
    readonly property var filteredMedia: {
        const all   = MediaService.allMedia
        const q     = root.query
        const tf    = root.typeFilter
        let base    = []
        for (let i = 0; i < all.length; i++) {
            const m = all[i]
            if (!m) continue
            if (tf === "image" && m.type !== "image") continue
            if (tf === "video" && m.type !== "video") continue
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
        return {
            kind:      m.type,    // "image" | "video"
            title:     m.title,
            subtitle:  "",
            pages:     [{ label: m.title, content: "" }],
            mediaId:   m.id,
            mediaPath: m.path
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
        const selected = AppState.mediaBatchSelection.slice()
        for (let i = 0; i < selected.length; i++) {
            const m = root.filteredMedia[selected[i]]
            if (m) MediaService.remove(m.id)
        }
        AppState.clearMediaBatchSelection()
    }

    // Bounds-clamp fluid index when the list shrinks.
    onFilteredMediaChanged: {
        const n = filteredMedia.length
        if (n === 0) {
            if (fluidIndex !== -1) AppState.setLibraryFluid(tabKey, -1)
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

    // ── Import affordance ───────────────────────────────────────────────
    // No QtQuick.Dialogs FileDialog — see header comment. The "+" button and
    // the empty-state CTA both call flashDropZone() to make the drop overlay
    // pulse on, hinting at the drag-and-drop import path. When MediaService
    // grows a native file-picker Q_INVOKABLE we can call it from here.
    Timer {
        id: flashTimer
        interval: 1400
        repeat: false
        onTriggered: dropZone.isOver = false
    }
    function flashDropZone() {
        dropZone.isOver = true
        flashTimer.restart()
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
                radius: 3
                color: clearBatchMa.containsMouse ? Theme.color.overlay : "transparent"
                AppIcon {
                    anchors.centerIn: parent
                    name: "x"; size: 10
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
            radius: 4
            color: addMa.containsMouse ? Theme.color.overlay : "transparent"
            border.color: Theme.color.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            AppIcon {
                anchors.centerIn: parent
                name: "plus"; size: 13
                color: Theme.color.textSecondary
            }

            MouseArea {
                id: addMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.flashDropZone()
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
                radius: 4
                color: batchDelMa.containsMouse ? Theme.color.liveSubtle : "transparent"

                Row {
                    id: batchDelRow
                    anchors.centerIn: parent
                    spacing: 4
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "trash"; size: 11
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
                radius: 4
                color: gridViewMa.containsMouse ? Theme.color.overlay : "transparent"
                AppIcon {
                    anchors.centerIn: parent
                    name: "layout-grid"; size: 13
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
                radius: 4
                color: listViewMa.containsMouse ? Theme.color.overlay : "transparent"
                AppIcon {
                    anchors.centerIn: parent
                    name: "layout-list"; size: 13
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
                radius: 4
                color: colsMa.containsMouse ? Theme.color.overlay : "transparent"

                Row {
                    id: colsRow
                    anchors.centerIn: parent
                    spacing: 4
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "grid-3x3"; size: 13
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
                        name: "chevron-down"; size: 9
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
                        const p = colsBtn.mapToItem(null, colsBtn.width, colsBtn.height + 4)
                        AppState.openModal("contextMenu", {
                            anchorX:   p.x - 160,
                            anchorY:   p.y,
                            menuWidth: 160,
                            items:     items
                        })
                    }
                }
            }

            // Sort menu
            Rectangle {
                id: sortBtn
                anchors.verticalCenter: parent.verticalCenter
                width: sortRow.implicitWidth + Theme.space.sm * 2
                height: 22
                radius: 4
                color: sortMa.containsMouse ? Theme.color.overlay : "transparent"

                Row {
                    id: sortRow
                    anchors.centerIn: parent
                    spacing: 4
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: AppState.mediaSortOrder === "asc" ? "sort-asc" : "sort-desc"
                        size: 13
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
                        name: "chevron-down"; size: 9
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
                        const p = sortBtn.mapToItem(null, sortBtn.width, sortBtn.height + 4)
                        AppState.openModal("contextMenu", {
                            anchorX:   p.x - 160,
                            anchorY:   p.y,
                            menuWidth: 160,
                            items:     items
                        })
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
            radius: Theme.radius.lg
            color: Qt.rgba(Theme.color.brand.r, Theme.color.brand.g, Theme.color.brand.b, 0.18)
            border.color: Theme.color.brand
            border.width: 2

            Column {
                anchors.centerIn: parent
                spacing: Theme.space.sm
                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "cloud-upload"; size: 52
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
                text: qsTr("Drop files to import")
                onClicked: root.flashDropZone()
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
            anchors.fill: parent
            anchors.margins: Theme.space.sm
            clip: true
            cacheBuffer: 600
            visible: AppState.mediaViewMode === "grid" && root.filteredMedia.length > 0
            currentIndex: root.fluidIndex
            model: root.filteredMedia
            cellWidth:  Math.max(80, Math.floor(width / Math.max(1, AppState.mediaGridColumns)))
            cellHeight: Math.floor(cellWidth * 9.0 / 16.0) + 4

            delegate: Item {
                id: cell
                width: grid.cellWidth
                height: grid.cellHeight

                readonly property bool _selected: grid.currentIndex === index
                readonly property bool _batch:    AppState.mediaBatchSelection.indexOf(index) !== -1
                readonly property bool _live:
                    AppState.libraryLiveActive
                    && AppState.libraryPreviewItem
                    && AppState.libraryPreviewItem.mediaId === modelData.id
                readonly property bool _logo:     root.isCurrentLogo(modelData.path)

                Rectangle {
                    id: thumb
                    anchors.fill: parent
                    anchors.margins: 3
                    radius: Theme.radius.sm
                    color: "#0d0d12"
                    border.color: cell._batch ? Theme.color.brand
                                : cell._selected ? Theme.color.preview
                                : cellMa.containsMouse ? Theme.color.borderStrong
                                                       : "transparent"
                    border.width: 2

                    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                    // Image preview (best-effort — Qt Image handles png/jpg/etc).
                    Image {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: modelData.type === "image"
                        source: "file:///" + modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        sourceSize.width: 320
                        sourceSize.height: 180
                    }
                    // Video placeholder — a real thumbnail requires QMediaPlayer.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: modelData.type === "video"
                        color: "#13131a"
                        AppIcon {
                            anchors.centerIn: parent
                            name: "video"; size: 28
                            color: Theme.color.textTertiary
                        }
                    }

                    // Type badge (top-right)
                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 4
                        width: 18; height: 18
                        radius: 3
                        color: "#000000bb"
                        AppIcon {
                            anchors.centerIn: parent
                            name: modelData.type === "video" ? "video" : "image"
                            size: 10
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
                        radius: 3
                        color: Theme.color.success
                        AppIcon {
                            anchors.centerIn: parent
                            name: "sparkles"; size: 10
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
                        radius: 3
                        color: cell._batch ? Theme.color.brand : "#000000bb"
                        border.color: cell._batch ? Theme.color.brand : "#ffffff44"
                        border.width: 1
                        AppIcon {
                            anchors.centerIn: parent
                            visible: cell._batch
                            name: "check"; size: 10
                            color: "#ffffff"
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleBatch(index)
                        }
                    }

                    // LIVE pill (bottom-left)
                    Rectangle {
                        visible: cell._live
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.margins: 4
                        width: liveLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 3
                        color: Theme.color.live

                        Text {
                            id: liveLabel
                            anchors.centerIn: parent
                            text: qsTr("LIVE")
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 9
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.5
                        }
                    }

                    // Hover title gradient
                    Rectangle {
                        visible: cellMa.containsMouse
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 2
                        height: 22
                        radius: Theme.radius.sm
                        color: "#000000aa"

                        Text {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            text: modelData.title
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 10
                            elide: Text.ElideRight
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
                        if (mouse.button === Qt.RightButton) {
                            root.pushPreviewFor(index)
                            const p = mapToItem(null, mouse.x, mouse.y)
                            AppState.openModal("contextMenu", {
                                anchorX:   p.x,
                                anchorY:   p.y,
                                menuWidth: 220,
                                items: [
                                    { label: qsTr("Push to Live"), iconName: "play",
                                      action: function() { root.pushLiveFor(index) } },
                                    { label: qsTr("Add to Schedule"), iconName: "plus",
                                      action: function() { root.addToScheduleFor(index) } },
                                    { separator: true },
                                    { label: qsTr("Set as Logo Background"), iconName: "sparkles",
                                      detail: cell._logo ? "✓" : "",
                                      action: function() { ProjectionService.setLogoBgPath(modelData.path) } },
                                    { label: qsTr("Edit"),  iconName: "edit" },
                                    { label: qsTr("Duplicate"), iconName: "copy" },
                                    { separator: true },
                                    { label: modelData.isFavorite
                                            ? qsTr("Remove from Favorites")
                                            : qsTr("Add to Favorites"),
                                      iconName: modelData.isFavorite ? "heart-off" : "heart",
                                      action: function() { MediaService.toggleFavorite(modelData.id) } },
                                    { label: qsTr("Add to Collection…"), iconName: "folder" },
                                    { separator: true },
                                    { label: qsTr("Delete"), iconName: "trash", destructive: true,
                                      action: function() {
                                          AppState.openModal("confirm", {
                                              title:       qsTr("Delete media?"),
                                              body:        qsTr("Remove \"") + modelData.title + qsTr("\" from your library?"),
                                              confirmText: qsTr("Delete"),
                                              onConfirm:   function() { MediaService.remove(modelData.id) }
                                          })
                                      } }
                                ]
                            })
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
                        root.pushLiveFor(index)
                    }
                }
            }
        }

        // ── List view ───────────────────────────────────────────────────
        ListView {
            id: listView
            anchors.fill: parent
            anchors.margins: Theme.space.sm
            clip: true
            cacheBuffer: 400
            visible: AppState.mediaViewMode === "list" && root.filteredMedia.length > 0
            model: root.filteredMedia
            spacing: 2
            currentIndex: root.fluidIndex

            delegate: Item {
                id: listRow
                width: listView.width
                height: 48

                readonly property bool _selected: listView.currentIndex === index
                readonly property bool _batch:    AppState.mediaBatchSelection.indexOf(index) !== -1
                readonly property bool _live:
                    AppState.libraryLiveActive
                    && AppState.libraryPreviewItem
                    && AppState.libraryPreviewItem.mediaId === modelData.id
                readonly property bool _logo:     root.isCurrentLogo(modelData.path)

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.sm
                    anchors.rightMargin: Theme.space.sm
                    radius: Theme.radius.md
                    color: listRow._batch    ? Theme.color.brandSubtle
                         : listRow._selected ? Theme.color.previewSubtle
                         : rowMa.containsMouse ? Theme.color.elevated
                                               : "transparent"
                    border.color: listRow._selected ? Theme.color.preview
                                : listRow._batch    ? Theme.color.brand
                                                    : "transparent"
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

                // Batch-checkbox (visible on hover or while batch is active)
                Rectangle {
                    id: rowCheckbox
                    visible: rowMa.containsMouse || listRow._batch
                          || AppState.mediaBatchSelection.length > 0
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16
                    radius: 3
                    color: listRow._batch ? Theme.color.brand : "transparent"
                    border.color: listRow._batch ? Theme.color.brand : Theme.color.borderStrong
                    border.width: 1
                    AppIcon {
                        anchors.centerIn: parent
                        visible: listRow._batch
                        name: "check"; size: 10
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
                    radius: Theme.radius.sm
                    color: "#0d0d12"
                    clip: true

                    Image {
                        anchors.fill: parent
                        visible: modelData.type === "image"
                        source: "file:///" + modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 120
                        sourceSize.height: 70
                    }
                    AppIcon {
                        anchors.centerIn: parent
                        visible: modelData.type === "video"
                        name: "video"; size: 16
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
                            AppIcon { name: "sparkles"; size: 11; color: Theme.color.success }
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
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.xs

                    Rectangle {
                        visible: listRow._live
                        anchors.verticalCenter: parent.verticalCenter
                        width: rowLiveLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 3
                        color: Theme.color.live
                        Text {
                            id: rowLiveLabel
                            anchors.centerIn: parent
                            text: qsTr("LIVE")
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 9
                            font.weight: Theme.font.weightSemiBold
                        }
                    }
                    Rectangle {
                        visible: rowMa.containsMouse && !modelData.isFavorite
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18
                        radius: 3
                        color: favMa.containsMouse ? Theme.color.overlay : "transparent"
                        AppIcon {
                            anchors.centerIn: parent
                            name: "star"; size: 11
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
                        name: "heart"; size: 12
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
                        if (mouse.button === Qt.RightButton) {
                            root.pushPreviewFor(index)
                            const p = mapToItem(null, mouse.x, mouse.y)
                            AppState.openModal("contextMenu", {
                                anchorX:   p.x,
                                anchorY:   p.y,
                                menuWidth: 220,
                                items: [
                                    { label: qsTr("Push to Live"), iconName: "play",
                                      action: function() { root.pushLiveFor(index) } },
                                    { label: qsTr("Add to Schedule"), iconName: "plus",
                                      action: function() { root.addToScheduleFor(index) } },
                                    { separator: true },
                                    { label: qsTr("Set as Logo Background"), iconName: "sparkles",
                                      detail: listRow._logo ? "✓" : "",
                                      action: function() { ProjectionService.setLogoBgPath(modelData.path) } },
                                    { label: qsTr("Edit"), iconName: "edit" },
                                    { label: qsTr("Duplicate"), iconName: "copy" },
                                    { separator: true },
                                    { label: modelData.isFavorite
                                            ? qsTr("Remove from Favorites")
                                            : qsTr("Add to Favorites"),
                                      iconName: modelData.isFavorite ? "heart-off" : "heart",
                                      action: function() { MediaService.toggleFavorite(modelData.id) } },
                                    { separator: true },
                                    { label: qsTr("Delete"), iconName: "trash", destructive: true,
                                      action: function() {
                                          AppState.openModal("confirm", {
                                              title:       qsTr("Delete media?"),
                                              body:        qsTr("Remove \"") + modelData.title + qsTr("\" from your library?"),
                                              confirmText: qsTr("Delete"),
                                              onConfirm:   function() { MediaService.remove(modelData.id) }
                                          })
                                      } }
                                ]
                            })
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
                        root.pushLiveFor(index)
                    }
                }
            }
        }
    }

    // ── Keyboard navigation routed from TabSearchBar ────────────────────
    // Grid view treats Up/Down as column-jump and Left/Right as adjacent;
    // but since TabSearchBar only emits Up/Down/Activate, we treat them as
    // sequence-next/previous (which feels right when typing to filter).
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
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushLiveFor(root.fluidIndex)
        }
    }
}
