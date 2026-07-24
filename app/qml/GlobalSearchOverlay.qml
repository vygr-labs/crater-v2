import QtQuick
import QtQuick.Layouts

// Global search command palette (Ctrl+K). Mounted by ModalLayer when
// AppState.activeModal === "globalSearch".
//
// One query is fanned out across every library service and the hits are merged
// into a grouped, keyboard-navigable list (left). A detail pane (right)
// previews the focused hit — song lyrics, the full verse, a media thumbnail,
// a theme swatch — so the operator can confirm the right item before acting.
//
// Acting: Enter fires the per-type primary action from
// SettingsService.globalSearchActions (Preview / Reveal / Go Live, configurable
// per result type in Settings → Search). The detail pane exposes every
// applicable action as an explicit button, and modifier-Enter offers quick
// Go Live (Ctrl) / Add to Schedule (Shift). AppState.runGlobalSearchAction is
// the single dispatch point.
//
// Zero core C++ dependency beyond the existing Q_INVOKABLE searches: the
// canonical schedule-item builders below mirror the per-tab builders
// (SongsTab.buildItemFromSong, ScriptureTab.buildItemFromVerse,
// MediaTab.buildItemFromMedia, StrongsDictionaryView.buildItem) so a palette
// hit stages / projects / schedules byte-for-byte like selecting it in its tab.
ModalShell {
    id: root

    // A wide, tall surface — the two panes need room. ModalShell clamps to the
    // window with a 48px inset, so on small windows it shrinks gracefully.
    dialogWidth: 880
    dialogHeight: 600
    showHeader: false

    // ── Groups, in display order ─────────────────────────────────────────
    readonly property var groupDefs: [
        { type: "scripture", label: qsTr("Scripture") },
        { type: "songs",     label: qsTr("Songs") },
        { type: "strongs",   label: qsTr("Strong's") },
        { type: "media",     label: qsTr("Media") },
        { type: "themes",    label: qsTr("Themes") }
    ]
    // Rows shown per group before a "+N more — reveal to see all" note. Keeps
    // the palette scannable; the operator narrows the query or reveals the tab
    // for the long tail.
    readonly property int perGroupCap: 6
    // Minimum characters before we search — one letter matches half the corpus
    // and just churns. Two is the same floor the tabs' FTS uses in practice.
    readonly property int minChars: 2

    // Flat, display-ordered rows. Each carries enough to render, to reveal, and
    // to lazily build its canonical item on action:
    //   { type, groupLabel, isGroupStart, groupShown, groupTotal,
    //     title, subtitle, source }
    property var    flatRows: []
    property string shownQuery: ""
    property int    currentIndex: 0

    // Which lyric section (verse / chorus) of the focused song the operator has
    // singled out to stage. -1 means "auto" — fall back to the section that
    // actually matched the query (matchedSectionIndex). Reset whenever the
    // focused row changes so each song starts on its matched verse, not a stale
    // index carried over from the previous row.
    property int selectedSectionIndex: -1
    onCurrentIndexChanged: selectedSectionIndex = -1

    readonly property var currentRow:
        (currentIndex >= 0 && currentIndex < flatRows.length) ? flatRows[currentIndex] : null

    // Full song for the detail pane (lyrics). Re-fetched only when the focused
    // row is a different song — cheap point lookup, but no reason to repeat it
    // on every arrow press over non-song rows.
    readonly property var currentFullSong:
        (currentRow && currentRow.type === "songs" && currentRow.source)
            ? SongService.fetchSong(currentRow.source.id)
            : null

    // ── Song lyric-section targeting ──────────────────────────────────────
    // The palette lets the operator pick WHICH verse/chorus of a song to stage
    // and defaults to the one the query matched, so pressing Enter opens Preview
    // on the right slide. These helpers also translate a song's raw section
    // index into the Preview pane's page index, which skips sections that have
    // no lyric lines (mirroring PreviewPanel's content filter).

    readonly property int sectionCount:
        (currentFullSong && currentFullSong.sections) ? currentFullSong.sections.length : 0

    // First section whose lyrics contain the query (whole phrase preferred, then
    // any query word); 0 when nothing matches, so a song always has a target.
    function matchedSectionIndex(song, q) {
        if (!song || !song.sections) return 0
        const lq = String(q || "").toLowerCase().trim()
        if (lq.length === 0) return 0
        for (let i = 0; i < song.sections.length; i++) {
            const sec = song.sections[i]
            if (sec && sec.lines && sec.lines.join("\n").toLowerCase().indexOf(lq) !== -1)
                return i
        }
        const words = lq.split(/\s+/).filter(function(w) { return w.length >= 2 })
        for (let i = 0; i < song.sections.length; i++) {
            const sec = song.sections[i]
            if (!sec || !sec.lines) continue
            const joined = sec.lines.join("\n").toLowerCase()
            for (let w = 0; w < words.length; w++)
                if (joined.indexOf(words[w]) !== -1) return i
        }
        return 0
    }

    // Concrete section for the focused song: the operator's explicit pick if
    // any, else the matched section.
    function effectiveSectionIndex() {
        if (!currentFullSong) return 0
        if (selectedSectionIndex >= 0) return selectedSectionIndex
        return matchedSectionIndex(currentFullSong, shownQuery)
    }

    // Raw section index -> Preview page index (lyric-bearing sections before it).
    function sectionToPreviewPage(song, sectionIdx) {
        if (!song || !song.sections) return 0
        let page = 0
        for (let i = 0; i < sectionIdx && i < song.sections.length; i++) {
            const sec = song.sections[i]
            if (sec && sec.lines && sec.lines.length > 0) page++
        }
        return page
    }

    // Tab / Shift+Tab within the focused song's sections. Clamped, not wrapped.
    function moveSection(delta) {
        if (!currentFullSong || sectionCount <= 1) return
        let n = effectiveSectionIndex() + delta
        if (n < 0) n = 0
        if (n > sectionCount - 1) n = sectionCount - 1
        selectedSectionIndex = n
    }

    // ── Canonical schedule-item builders (mirror the per-tab builders) ────

    function buildVerseItem(v) {
        if (!v || !v.text || v.text.length === 0) return null
        const code = v.translationCode
                   || String(AppState.activeLibraryGroup.scripture || "").toUpperCase()
        return {
            kind:     "scripture",
            title:    v.book + " " + v.chapter + ":" + v.verse + " (" + code + ")",
            subtitle: "",
            pages:    [{ label: v.book + " " + v.chapter + ":" + v.verse, content: v.text }],
            scriptureRef: {
                translationCode: code,
                book:            v.book,
                chapter:         v.chapter,
                verse:           v.verse
            }
        }
    }

    function buildSongItem(song) {
        if (!song || !song.id) return null
        let pages = []
        for (let i = 0; i < song.sections.length; i++) {
            const sec = song.sections[i]
            pages.push({
                label:   sec.label || "",
                content: (sec.lines && sec.lines.length > 0) ? sec.lines.join("\n") : ""
            })
        }
        if (pages.length === 0)
            pages = [{ label: "", content: song.title + (song.author ? "\n" + song.author : "") }]
        let subtitleParts = []
        if (SettingsService.showSongAuthor && song.author) subtitleParts.push(song.author)
        if (SettingsService.showSongCcli && song.ccli)     subtitleParts.push("CCLI " + song.ccli)
        return {
            kind:     "song",
            title:    song.title,
            subtitle: subtitleParts.join(" · "),
            pages:    pages,
            songId:   song.id,
            themeId:  song.themeId || 0
        }
    }

    function buildMediaItem(m) {
        if (!m) return null
        let pages = [{ label: m.title, content: "" }]
        if (m.type === "pdf" && m.pageCount > 1) {
            pages = []
            for (let i = 0; i < m.pageCount; ++i)
                pages.push({ label: qsTr("Page %1").arg(i + 1), content: "" })
        }
        return {
            kind:      m.type,
            title:     m.title,
            subtitle:  m.type === "pdf"
                           ? qsTr("PDF · %1 page%2").arg(m.pageCount).arg(m.pageCount === 1 ? "" : "s")
                           : "",
            pages:     pages,
            mediaId:   m.id,
            mediaPath: m.path,
            pageCount: m.pageCount,
            fitMode:   m.fitMode,
            cropRect:  m.cropRect,
            loopVideo: m.loopVideo,
            muted:     m.muted
        }
    }

    function buildStrongsItem(entry) {
        if (!entry || !entry.valid) return null
        const secs = StrongsService.sections(entry.word)
        let pages = []
        for (let i = 0; i < secs.length; i++)
            pages.push({ label: secs[i].label, content: secs[i].content })
        if (pages.length === 0)
            pages = [{ label: entry.word, content: entry.definition || entry.word }]
        return {
            kind:       "strongs",
            title:      entry.title,
            subtitle:   entry.partOfSpeech || "",
            pages:      pages,
            themeId:    0,
            strongsRef: { word: entry.word }
        }
    }

    // Assemble the { type, title, item?, scriptureRef?, songId?, revealQuery? }
    // shape AppState.runGlobalSearchAction / revealResult expect. `needItem`
    // skips the (DB-touching) item build for reveal-only invocations.
    function resultFor(row, needItem) {
        if (!row) return null
        let r = { type: row.type, title: row.title }
        if (row.type === "scripture") {
            const h = row.source
            r.scriptureRef = {
                translationCode: h.translationCode, book: h.book,
                chapter: h.chapter, verse: h.verse
            }
            if (needItem) r.item = buildVerseItem(h)
        } else if (row.type === "songs") {
            r.songId = row.source.id
            r.revealQuery = row.title
            // The Preview slide to open on: the matched / operator-selected
            // lyric section. Only meaningful for the focused row, whose full
            // song (with sections) is loaded — other rows stage from page 0.
            if (currentFullSong && currentFullSong.id === row.source.id)
                r.page = sectionToPreviewPage(currentFullSong, effectiveSectionIndex())
            if (needItem) r.item = buildSongItem(SongService.fetchSong(row.source.id))
        } else if (row.type === "media") {
            r.revealQuery = row.title
            if (needItem) r.item = buildMediaItem(row.source)
        } else if (row.type === "strongs") {
            r.revealQuery = row.source.word
            if (needItem) r.item = buildStrongsItem(row.source)
        } else if (row.type === "themes") {
            r.revealQuery = row.title
        }
        return r
    }

    // ── Aggregation ──────────────────────────────────────────────────────

    function mediaSubtitle(m) {
        if (m.type === "video" && m.durationMs > 0) {
            const s = Math.round(m.durationMs / 1000)
            const mm = Math.floor(s / 60), ss = s % 60
            return qsTr("Video · %1:%2").arg(mm).arg(ss < 10 ? "0" + ss : String(ss))
        }
        if (m.type === "pdf")   return qsTr("PDF · %1 page%2").arg(m.pageCount).arg(m.pageCount === 1 ? "" : "s")
        if (m.type === "video") return qsTr("Video")
        return qsTr("Image")
    }

    function themeKindLabel(kind) {
        if (kind === "song")      return qsTr("Song theme")
        if (kind === "scripture") return qsTr("Scripture theme")
        return qsTr("Presentation theme")
    }

    // Gather up to a sane number of raw hits for one group. Returns
    // [{ title, subtitle, source }]. Kept per-group so recompute() can cap and
    // flatten uniformly.
    function collect(type, q) {
        let out = []
        if (type === "scripture") {
            const code = String(AppState.activeLibraryGroup.scripture || "").toUpperCase()
            // Reference-style queries ("john 3:16") — the trigram FTS often
            // misses these, so resolve directly and surface it first.
            const ref = BibleService.parseReference(q, code)
            const haveRef = ref && ref.text && ref.text.length > 0
            if (haveRef)
                out.push({ title: ref.book + " " + ref.chapter + ":" + ref.verse + " (" + code + ")",
                           subtitle: ref.text, source: ref })
            const hits = BibleService.search(q, code)
            for (let i = 0; i < hits.length; i++) {
                const h = hits[i]
                if (haveRef && h.book === ref.book && h.chapter === ref.chapter && h.verse === ref.verse)
                    continue  // don't repeat the direct reference
                out.push({ title: h.book + " " + h.chapter + ":" + h.verse
                                  + " (" + (h.translationCode || code) + ")",
                           subtitle: h.text, source: h })
            }
        } else if (type === "songs") {
            const songs = SongService.search(q)
            for (let j = 0; j < songs.length; j++)
                out.push({ title: songs[j].title, subtitle: songs[j].author || "", source: songs[j] })
        } else if (type === "strongs") {
            // Only when Strong's is available AND its tab is on — otherwise a
            // hit's Reveal would land on a tab that isn't there.
            if (!StrongsService.available || !SettingsService.showStrongsTab) return out
            const entries = StrongsService.search(q)
            for (let k = 0; k < entries.length; k++)
                out.push({ title: entries[k].title,
                           subtitle: entries[k].definition || entries[k].partOfSpeech || "",
                           source: entries[k] })
        } else if (type === "media") {
            const all = MediaService.allMedia
            const lq = q.toLowerCase()
            for (let m = 0; m < all.length; m++)
                if (String(all[m].title).toLowerCase().indexOf(lq) !== -1)
                    out.push({ title: all[m].title, subtitle: mediaSubtitle(all[m]), source: all[m] })
        } else if (type === "themes") {
            const themes = ThemeService.allThemes
            const lq2 = q.toLowerCase()
            for (let t = 0; t < themes.length; t++)
                if (String(themes[t].name).toLowerCase().indexOf(lq2) !== -1)
                    out.push({ title: themes[t].name, subtitle: themeKindLabel(themes[t].kind),
                               source: themes[t] })
        }
        return out
    }

    function recompute() {
        const q = String(AppState.globalSearchQuery || "").trim()
        shownQuery = q
        currentIndex = 0
        if (q.length < minChars) { flatRows = []; return }

        let rows = []
        for (let gi = 0; gi < groupDefs.length; gi++) {
            const def = groupDefs[gi]
            const found = collect(def.type, q)
            if (!found || found.length === 0) continue
            const shown = Math.min(found.length, perGroupCap)
            for (let i = 0; i < shown; i++) {
                rows.push({
                    type:         def.type,
                    groupLabel:   def.label,
                    isGroupStart: (i === 0),
                    groupShown:   shown,
                    groupTotal:   found.length,
                    title:        found[i].title,
                    subtitle:     found[i].subtitle,
                    source:       found[i].source
                })
            }
        }
        flatRows = rows
    }

    // ── Action dispatch ──────────────────────────────────────────────────

    // Actions offered for a type, with the configured primary flagged. Themes
    // have only Reveal (no projectable content).
    function actionsForType(type) {
        if (!type) return []
        const primary = (SettingsService.globalSearchActions || ({}))[type] || "reveal"
        let list = (type === "themes")
            ? [{ id: "reveal", label: qsTr("Reveal") }]
            : [{ id: "preview",  label: qsTr("Preview") },
               { id: "golive",   label: qsTr("Go Live") },
               { id: "schedule", label: qsTr("Add to Schedule") },
               { id: "reveal",   label: qsTr("Reveal") }]
        for (let i = 0; i < list.length; i++) list[i].primary = (list[i].id === primary)
        return list
    }

    // Enter / row-click — the per-type primary action (no override).
    function activateCurrent() {
        if (!currentRow) return
        AppState.runGlobalSearchAction(resultFor(currentRow, currentRow.type !== "themes"))
    }

    // A specific action button / modifier-Enter.
    function fireAction(row, actionId) {
        if (!row) return
        const needItem = (actionId !== "reveal")
        AppState.runGlobalSearchAction(resultFor(row, needItem), actionId)
    }

    function moveSelection(delta) {
        if (flatRows.length === 0) return
        let n = currentIndex + delta
        if (n < 0) n = 0
        if (n > flatRows.length - 1) n = flatRows.length - 1
        currentIndex = n
        resultsList.positionViewAtIndex(n, ListView.Contain)
    }

    // ── Debounced recompute on query change ──────────────────────────────
    Timer {
        id: debounce
        interval: 200   // matches ScriptureTab's FTS debounce feel
        onTriggered: root.recompute()
    }
    Connections {
        target: AppState
        function onGlobalSearchQueryChanged() { debounce.restart() }
    }

    Component.onCompleted: {
        // Restore any last-session query, run it immediately (no debounce wait),
        // focus the input and select the text so a fresh query overwrites it.
        recompute()
        Qt.callLater(function() {
            queryInput.forceActiveFocus()
            queryInput.selectAll()
        })
    }

    // ── Palette body ─────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Search input row ─────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: "transparent"

            AppIcon {
                id: searchIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                color: Theme.color.textTertiary
                size: Theme.icon.lg
            }

            TextInput {
                id: queryInput
                anchors.left: searchIcon.right
                anchors.leftMargin: Theme.space.md
                anchors.right: escHint.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 4
                selectByMouse: true
                clip: true
                text: AppState.globalSearchQuery
                onTextChanged: {
                    if (text !== AppState.globalSearchQuery)
                        AppState.globalSearchQuery = text
                }

                Text {
                    visible: queryInput.text.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Search Scripture, Songs, Strong's, Media, Themes…")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 4
                }

                // All list navigation lives here: the window-level Up/Down/
                // Enter shortcuts are disabled while a modal is open, so the
                // palette owns these keys with no double-fire risk.
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Up) {
                        root.moveSelection(-1); event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                        root.moveSelection(1); event.accepted = true
                    } else if (event.key === Qt.Key_Tab) {
                        // Tab / Shift+Tab step through the focused song's lyric
                        // sections (Left/Right stay free for text-cursor edits).
                        // A no-op unless a multi-section song is focused.
                        root.moveSection((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Backtab) {
                        root.moveSection(-1); event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (!root.currentRow) { event.accepted = true; return }
                        if (event.modifiers & Qt.ControlModifier)
                            root.fireAction(root.currentRow, "golive")
                        else if (event.modifiers & Qt.ShiftModifier)
                            root.fireAction(root.currentRow, "schedule")
                        else
                            root.activateCurrent()
                        event.accepted = true
                    }
                }
            }

            Rectangle {
                id: escHint
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                width: escText.implicitWidth + 12
                height: 20
                radius: 0
                color: Theme.color.elevated
                border.color: Theme.color.borderSubtle
                border.width: 1
                Text {
                    id: escText
                    anchors.centerIn: parent
                    text: qsTr("Esc")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 11
                }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

        // ── Results + detail ─────────────────────────────────────────────
        Item {
            id: bodyRow
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ── Left: grouped results ────────────────────────────────────
            Item {
                id: leftPane
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.round(parent.width * 0.52)

                // Empty / no-result states.
                Text {
                    anchors.centerIn: parent
                    width: parent.width - Theme.space.xxl * 2
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: root.flatRows.length === 0
                    text: root.shownQuery.length < root.minChars
                          ? qsTr("Type at least %1 characters to search across your libraries.").arg(root.minChars)
                          : qsTr("No results for “%1”.").arg(root.shownQuery)
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }

                ListView {
                    id: resultsList
                    anchors.fill: parent
                    visible: root.flatRows.length > 0
                    clip: true
                    model: root.flatRows
                    currentIndex: root.currentIndex
                    keyNavigationEnabled: false
                    boundsBehavior: Flickable.StopAtBounds
                    highlightMoveDuration: 80

                    delegate: Item {
                        id: rowItem
                        required property int index
                        required property var modelData
                        width: ListView.view.width
                        implicitHeight: (modelData.isGroupStart ? groupHeader.height : 0) + rowBody.height

                        readonly property bool current: index === root.currentIndex

                        // Group header — shown above the first row of each group.
                        Item {
                            id: groupHeader
                            visible: modelData.isGroupStart
                            height: visible ? 28 : 0
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.space.lg
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 4
                                text: modelData.groupLabel.toUpperCase()
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                font.weight: Theme.font.weightSemiBold
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.space.lg
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 4
                                visible: modelData.groupTotal > modelData.groupShown
                                text: qsTr("+%1 more").arg(modelData.groupTotal - modelData.groupShown)
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }
                        }

                        Rectangle {
                            id: rowBody
                            anchors.top: modelData.isGroupStart ? groupHeader.bottom : parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 44
                            color: rowItem.current ? Theme.color.overlay
                                 : rowMa.containsMouse ? Theme.color.canvas
                                 : "transparent"

                            Column {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.space.lg
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.space.lg
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.title
                                    color: Theme.color.textPrimary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.bodySize
                                    font.weight: rowItem.current ? Theme.font.weightSemiBold
                                                                 : Theme.font.weightMedium
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    visible: modelData.subtitle && modelData.subtitle.length > 0
                                    text: modelData.subtitle
                                    color: Theme.color.textTertiary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.smallSize
                                }
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.currentIndex = index
                                onClicked: { root.currentIndex = index; root.activateCurrent() }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: bodyDivider
                anchors.left: leftPane.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: Theme.color.borderSubtle
            }

            // ── Right: detail pane ───────────────────────────────────────
            Item {
                anchors.left: bodyDivider.right
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom

                // Placeholder when nothing is focused.
                Text {
                    anchors.centerIn: parent
                    width: parent.width - Theme.space.xxl
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: !root.currentRow
                    text: qsTr("Select a result to preview it here.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }

                ColumnLayout {
                    visible: !!root.currentRow
                    anchors.fill: parent
                    anchors.margins: Theme.space.lg
                    spacing: Theme.space.md

                    // Title + subtitle.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: root.currentRow ? root.currentRow.title : ""
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize + 3
                            font.weight: Theme.font.weightSemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.currentRow && root.currentRow.subtitle
                                     && root.currentRow.type !== "scripture"
                                     && root.currentRow.type !== "strongs"
                            wrapMode: Text.WordWrap
                            text: root.currentRow ? root.currentRow.subtitle : ""
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }

                    // Type-specific body — scrolls if long.
                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentHeight: detailBody.height
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: detailBody
                            width: parent.width
                            spacing: Theme.space.sm

                            // Scripture / Strong's / song lyrics — text bodies.
                            Text {
                                width: parent.width
                                visible: root.currentRow
                                    && (root.currentRow.type === "scripture"
                                        || root.currentRow.type === "strongs")
                                wrapMode: Text.WordWrap
                                text: root.currentRow ? (root.currentRow.subtitle || "") : ""
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize + 1
                                lineHeight: 1.25
                            }

                            // Song lyrics — every section, so the operator can
                            // confirm the song AND pick which verse to stage.
                            // The matched (or explicitly selected) section wears
                            // the gold "staged" chrome so it's clear what Enter
                            // will open in Preview; click a section to retarget,
                            // double-click to stage it straight away.
                            Repeater {
                                model: (root.currentRow && root.currentRow.type === "songs"
                                        && root.currentFullSong)
                                       ? root.currentFullSong.sections : []
                                delegate: Rectangle {
                                    id: secRect
                                    required property int index
                                    required property var modelData
                                    width: detailBody.width
                                    height: secCol.implicitHeight + Theme.space.sm * 2
                                    readonly property bool selected: root.effectiveSectionIndex() === index
                                    color: selected ? Theme.color.previewSubtle
                                         : secMa.containsMouse ? Theme.color.overlay
                                         : "transparent"
                                    border.color: selected ? Theme.color.previewMuted : "transparent"
                                    border.width: 1

                                    // Left accent rail on the staged section.
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        width: 2
                                        visible: secRect.selected
                                        color: Theme.color.preview
                                    }

                                    Column {
                                        id: secCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.leftMargin: Theme.space.sm
                                        anchors.rightMargin: Theme.space.sm
                                        anchors.topMargin: Theme.space.sm
                                        spacing: 1
                                        Text {
                                            visible: secRect.modelData.label && secRect.modelData.label.length > 0
                                            text: secRect.modelData.label
                                            color: secRect.selected ? Theme.color.preview : Theme.color.textTertiary
                                            font.family: Theme.font.family
                                            font.pixelSize: Theme.font.smallSize
                                            font.weight: Theme.font.weightSemiBold
                                        }
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.WordWrap
                                            text: (secRect.modelData.lines && secRect.modelData.lines.length > 0)
                                                  ? secRect.modelData.lines.join("\n") : ""
                                            color: Theme.color.textPrimary
                                            font.family: Theme.font.family
                                            font.pixelSize: Theme.font.bodySize
                                            lineHeight: 1.2
                                        }
                                    }

                                    MouseArea {
                                        id: secMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.selectedSectionIndex = secRect.index
                                        onDoubleClicked: {
                                            root.selectedSectionIndex = secRect.index
                                            root.activateCurrent()
                                        }
                                    }
                                }
                            }

                            // Media — thumbnail (images) or a type glyph.
                            Rectangle {
                                visible: root.currentRow && root.currentRow.type === "media"
                                width: parent.width
                                height: 180
                                color: Theme.color.canvas
                                border.color: Theme.color.borderSubtle
                                border.width: 1

                                Image {
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    visible: root.currentRow && root.currentRow.type === "media"
                                             && root.currentRow.source
                                             && root.currentRow.source.type === "image"
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    cache: false
                                    source: (root.currentRow && root.currentRow.source
                                             && root.currentRow.source.type === "image")
                                            ? "file:///" + String(root.currentRow.source.path).replace(/\\/g, "/")
                                            : ""
                                }
                                AppIcon {
                                    anchors.centerIn: parent
                                    visible: root.currentRow && root.currentRow.source
                                             && root.currentRow.source.type !== "image"
                                    name: (root.currentRow && root.currentRow.source
                                           && root.currentRow.source.type === "video") ? "video" : "file-text"
                                    color: Theme.color.textTertiary
                                    size: 48
                                }
                            }

                            // Theme — a swatch + kind.
                            Rectangle {
                                visible: root.currentRow && root.currentRow.type === "themes"
                                width: parent.width
                                height: 120
                                radius: 0
                                border.color: Theme.color.borderSubtle
                                border.width: 1
                                color: {
                                    const t = root.currentRow ? root.currentRow.source : null
                                    if (t && t.tokens && t.tokens.background && t.tokens.background.color)
                                        return t.tokens.background.color
                                    return Theme.color.canvas
                                }
                            }
                        }
                    }

                    // ── Action bar — every applicable action for the focused
                    // row. The configured primary (what Enter fires) is the
                    // brand button; the rest are ghost buttons. This is the
                    // "multiple actions per row" surface.
                    Flow {
                        Layout.fillWidth: true
                        visible: !!root.currentRow
                        spacing: Theme.space.sm

                        Repeater {
                            model: root.currentRow ? root.actionsForType(root.currentRow.type) : []
                            delegate: Loader {
                                required property var modelData
                                sourceComponent: modelData.primary ? primaryBtn : ghostBtn
                                onLoaded: {
                                    item.text = modelData.label
                                    item.actionId = modelData.id
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

        // ── Footer: keyboard hints ───────────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                // Surface the ⇥ verse-switcher hint only when a multi-section
                // song is focused — it's meaningless for every other row.
                text: (root.currentRow && root.currentRow.type === "songs" && root.sectionCount > 1)
                      ? qsTr("↑↓ Navigate   ·   ⇥ Verse   ·   ↵ Primary   ·   Ctrl+↵ Go Live   ·   Shift+↵ Schedule   ·   Esc Close")
                      : qsTr("↑↓ Navigate   ·   ↵ Primary   ·   Ctrl+↵ Go Live   ·   Shift+↵ Schedule   ·   Esc Close")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                elide: Text.ElideRight
            }
        }
    }

    // ── Action-button components (text + actionId injected by the Loader) ──
    Component {
        id: primaryBtn
        PrimaryButton {
            property string actionId: ""
            variant: "brand"
            onClicked: root.fireAction(root.currentRow, actionId)
        }
    }
    Component {
        id: ghostBtn
        GhostButton {
            property string actionId: ""
            onClicked: root.fireAction(root.currentRow, actionId)
        }
    }
}
