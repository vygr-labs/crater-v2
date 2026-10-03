import QtQuick

// Id-keyed multi-selection for one library tab (songs, media, presentations,
// themes). Every tab instantiates one, so the four share a single set of
// click rules instead of four copies that drift apart.
//
// State lives in AppState.librarySelection[tabKey] (transient UI state), as
// item IDS rather than row indices: the operator can tick three songs, change
// the sort or narrow the search, and the same three songs stay ticked. Ids
// that leave the library (deleted here or elsewhere) are pruned whenever
// `universe` changes.
//
// Two kinds of "selected", kept apart on purpose:
//   - the tab's current row (libraryFluidIndex) is the single item Preview
//     shows. Plain click, the arrow keys and Enter keep driving it exactly
//     as before.
//   - the checked set held here is what bulk actions act on. It only grows
//     through Ctrl+click, Shift+click, a row checkbox or Ctrl+A.
//
// Click rules (handleClick / handleRightClick):
//   plain click       clears the checked set; the tab then does its usual
//                     single-select (and the row becomes the Shift pivot)
//   Ctrl+click        toggles the row. Starting from nothing checked, the
//                     current row comes along too, as in a file manager.
//   Shift+click       checks the range from the pivot to the row
//                     (Ctrl+Shift adds the range to what is already checked)
//   checkbox          toggles that row only, never touching the current row
//   right-click       on a checked row with 2+ checked: the bulk menu.
//                     On an unchecked row: clears the set, single menu.
QtObject {
    id: sel

    // Which AppState.librarySelection slot this drives.
    property string tabKey: ""
    // Rows as currently shown (filtered + sorted). Ranges and Select all
    // follow this order. Each entry needs an `id`.
    property var items: []
    // The whole library, unfiltered. Selected ids missing from it are gone
    // and get pruned.
    property var universe: []
    // Id of the tab's current (fluid) row, or null when there is none.
    property var currentId: null

    readonly property var ids: AppState.librarySelection[tabKey] || []
    readonly property int count: ids.length
    // Any row checked.
    readonly property bool active: count > 0
    // The tab's Select toggle (AppState.librarySelectMode).
    readonly property bool selectMode: !!AppState.librarySelectMode[tabKey]
    // Row checkboxes show in select mode, or once Ctrl / Shift+click has
    // checked something. Never on hover alone.
    readonly property bool showChecks: selectMode || active
    function setSelectMode(on) { AppState.setLibrarySelectMode(tabKey, on) }

    readonly property var _set: {
        let s = {}
        const a = ids
        for (let i = 0; i < a.length; i++) s[String(a[i])] = true
        return s
    }

    // Checked rows the current search / filter hides. Bulk actions still
    // apply to them, so the bar says how many there are.
    readonly property int hiddenCount: {
        if (count === 0) return 0
        const s = _set
        const list = items || []
        let visible = 0
        for (let i = 0; i < list.length; i++)
            if (list[i] && s[String(list[i].id)] === true) visible++
        return Math.max(0, count - visible)
    }

    // Every visible row already checked: Select all has nothing to add.
    readonly property bool allVisibleSelected: {
        const s = _set
        const list = items || []
        if (list.length === 0) return false
        for (let i = 0; i < list.length; i++)
            if (!list[i] || s[String(list[i].id)] !== true) return false
        return true
    }

    function isSelected(id) { return _set[String(id)] === true }

    function setIds(a)    { AppState.setLibrarySelection(tabKey, a) }
    function clear()      { AppState.clearLibrarySelection(tabKey) }
    function setAnchor(id) { AppState.setLibrarySelectionAnchor(tabKey, id) }

    // Position of `id` in a list of row objects (items / universe).
    function _indexIn(list, id) {
        if (id === null || id === undefined) return -1
        const k = String(id)
        for (let i = 0; i < list.length; i++)
            if (list[i] && String(list[i].id) === k) return i
        return -1
    }

    // Checkbox, and Ctrl+click once something is already checked.
    function toggle(id) {
        let next = ids.slice()
        const k = String(id)
        let at = -1
        for (let i = 0; i < next.length; i++) if (String(next[i]) === k) { at = i; break }
        if (at >= 0) next.splice(at, 1)
        else         next.push(id)
        setIds(next)
        setAnchor(id)
    }

    function selectAll() {
        const list = items || []
        let out = []
        for (let i = 0; i < list.length; i++) if (list[i]) out.push(list[i].id)
        setIds(out)
    }

    // Shift+click. The pivot is the last row clicked without Shift; failing
    // that (or if the filter has hidden it) the current row; failing that,
    // the click just toggles.
    function selectRangeTo(id, additive) {
        const list = items || []
        const to = _indexIn(list, id)
        if (to < 0) return
        let from = _indexIn(list, AppState.librarySelectionAnchor[tabKey])
        if (from < 0 && currentId !== null && currentId !== undefined)
            from = _indexIn(list, currentId)
        if (from < 0) { toggle(id); return }
        const lo = Math.min(from, to)
        const hi = Math.max(from, to)
        let out = additive ? ids.slice() : []
        for (let i = lo; i <= hi; i++) out.push(list[i].id)
        setIds(out)   // setLibrarySelection de-duplicates
    }

    // Left-click policy. Returns true when the click was a selection gesture
    // and the tab should do nothing more; false for a plain click, after
    // which the tab runs its normal single-select (preview etc.).
    function handleClick(mouse, id) {
        const ctrl  = (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0
        const shift = (mouse.modifiers & Qt.ShiftModifier) !== 0
        if (shift) {
            selectRangeTo(id, ctrl)
            return true
        }
        if (ctrl) {
            const cur = currentId
            if (count === 0 && cur !== null && cur !== undefined
                    && String(cur) !== String(id) && _indexIn(items || [], cur) >= 0) {
                setIds([cur, id])
                setAnchor(id)
            } else {
                toggle(id)
            }
            return true
        }
        if (selectMode) {
            // Select mode: a plain click ticks the row, like its checkbox.
            toggle(id)
            setAnchor(id)
            return true
        }
        clear()
        setAnchor(id)
        return false
    }

    // Right-click policy. True means "open the bulk menu for the checked
    // rows and leave the current row alone". Otherwise any checked set is
    // dropped (the menu that opens acts on this one row, and a checked set
    // the menu ignores would be misleading) and the tab does its usual
    // right-click.
    function handleRightClick(id) {
        if (count >= 2 && isSelected(id)) return true
        if (count > 0 && !isSelected(id)) clear()
        return false
    }

    // The checked rows as objects: visible ones in on-screen order, then any
    // the filter hides, in library order. Bulk actions iterate this, so
    // "Add to schedule" appends in the order the operator sees.
    function selectedItems() {
        const s = _set
        let out = []
        let taken = {}
        const list = items || []
        for (let i = 0; i < list.length; i++) {
            const it = list[i]
            if (!it || s[String(it.id)] !== true) continue
            out.push(it)
            taken[String(it.id)] = true
        }
        if (out.length < count) {
            const all = universe || []
            for (let j = 0; j < all.length; j++) {
                const it = all[j]
                if (!it) continue
                const k = String(it.id)
                if (s[k] === true && !taken[k]) { out.push(it); taken[k] = true }
            }
        }
        return out
    }

    function selectedIds() {
        return selectedItems().map(function(it) { return it.id })
    }

    // Drop ids that are no longer in the library.
    function prune() {
        if (count === 0) return
        const all = universe || []
        let present = {}
        for (let i = 0; i < all.length; i++) if (all[i]) present[String(all[i].id)] = true
        const kept = ids.filter(function(id) { return present[String(id)] === true })
        if (kept.length !== ids.length) setIds(kept)
    }

    onUniverseChanged: prune()

    // Arrowing to a row makes it the Shift pivot, as a click would, so
    // "arrow down to a song, Shift+click further down" ranges from where
    // the operator actually is.
    onCurrentIdChanged: {
        if (currentId !== null && currentId !== undefined) setAnchor(currentId)
    }
}
