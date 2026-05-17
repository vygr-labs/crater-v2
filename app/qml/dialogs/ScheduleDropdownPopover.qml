import QtQuick

// Schedule dropdown — opens under the TopBar's "Schedule" pill button.
// Lists ScheduleService.savedSchedules with hover-revealed rename + delete
// icons on each row, then a set of action items at the bottom:
//   - "Save" (only when a schedule is loaded; updates that row)
//   - "Save as new…" / "Save current as…" (always; creates a new row)
//   - "Close loaded schedule" (only when a schedule is loaded)
//   - "New empty schedule" (clears working items + loaded pointer)
//
// Implemented bespoke (not via PopoverMenu) because PopoverMenu's flat model
// can't express per-row hover affordances. Visual chrome mirrors PopoverMenu
// so the popover hierarchy stays cohesive.
Item {
    id: root

    readonly property real anchorX: AppState.modalProps.anchorX || 0
    readonly property real anchorY: AppState.modalProps.anchorY || 0

    anchors.fill: parent
    z: 500

    function close() { AppState.closeModal() }

    // Human-readable relative time. Larger increments collapse to a date so the
    // dropdown doesn't end up with awkward "47 days ago" entries.
    function relTime(ms) {
        if (!ms) return ""
        const diff = Date.now() - ms
        if (diff < 60000)     return qsTr("Just now")
        if (diff < 3600000)   { const m = Math.floor(diff / 60000);   return m === 1 ? qsTr("1 minute ago") : qsTr("%1 minutes ago").arg(m) }
        if (diff < 86400000)  { const h = Math.floor(diff / 3600000); return h === 1 ? qsTr("1 hour ago")   : qsTr("%1 hours ago").arg(h) }
        if (diff < 604800000) { const d = Math.floor(diff / 86400000); return d === 1 ? qsTr("Yesterday")    : qsTr("%1 days ago").arg(d) }
        return Qt.formatDate(new Date(ms), "yyyy-MM-dd")
    }

    // Backdrop — catches clicks outside the popover body.
    MouseArea {
        anchors.fill: parent
        onPressed: function(mouse) { root.close(); mouse.accepted = true }
    }

    Rectangle {
        id: body
        x: Math.max(8, Math.min(root.anchorX, root.width - width - 8))
        y: Math.max(8, Math.min(root.anchorY, root.height - height - 8))
        width: 380
        height: contents.implicitHeight + Theme.space.sm * 2
        color: Theme.color.raised
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: Theme.radius.md

        // Subtle drop shadow.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            anchors.topMargin: 1
            radius: parent.radius + 1
            color: "#00000040"
            z: -1
        }

        // Absorb clicks landing on blank areas of the body so they don't
        // fall through to the backdrop's onPressed handler (which would
        // close the popover) and onward. `Qt.NoButton` looks like blocking
        // but actually rejects the event and lets Qt propagate it — see
        // the matching note in ModalShell.qml.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onPressed: function(m) { m.accepted = true }
            onClicked: function(m) { m.accepted = true }
            onWheel:   function(w) { w.accepted = true }
        }

        Column {
            id: contents
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.space.sm
            spacing: 2

            // ── Saved schedules ─────────────────────────────────────────
            Repeater {
                model: ScheduleService.savedSchedules
                delegate: Item {
                    id: savedRow
                    width: contents.width
                    height: 38

                    readonly property bool _loaded:
                        ScheduleService.loadedScheduleId === modelData.id
                    readonly property var _model: modelData

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius.sm
                        color: rowMa.containsMouse ? Theme.color.overlay : "transparent"

                        // Loaded checkmark / file-text default.
                        AppIcon {
                            id: leftIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            name: savedRow._loaded ? "check" : "file-text"
                            size: Theme.icon.sm
                            color: savedRow._loaded ? Theme.color.brand
                                                    : Theme.color.textSecondary
                        }

                        // Name.
                        Text {
                            id: nameText
                            anchors.left: leftIcon.right
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: detailText.left
                            anchors.rightMargin: Theme.space.sm
                            text: savedRow._model.name
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: savedRow._loaded ? Theme.font.weightMedium
                                                          : Theme.font.weightRegular
                            elide: Text.ElideRight
                        }

                        // Detail: item count + relative time. Squeezed when the
                        // hover actions appear by always reserving their width
                        // in the layout (the icons fade in/out rather than
                        // appear/disappear so the metric doesn't reflow).
                        Text {
                            id: detailText
                            anchors.right: actions.left
                            anchors.rightMargin: Theme.space.sm
                            anchors.verticalCenter: parent.verticalCenter
                            text: savedRow._model.itemCount
                                + (savedRow._model.itemCount === 1 ? qsTr(" item · ") : qsTr(" items · "))
                                + root.relTime(savedRow._model.modifiedAt)
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }

                        // Hover affordances. Width is reserved in layout
                        // regardless of hover; opacity is the only thing that
                        // changes, so click targets are stable and the row's
                        // metrics don't shift as the cursor enters.
                        Row {
                            id: actions
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.sm
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            width: 52
                            opacity: rowMa.containsMouse || renameMa.containsMouse || delMa.containsMouse
                                   ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

                            // Rename icon
                            Item {
                                width: 24; height: 24
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.radius.sm
                                    color: renameMa.containsMouse ? Theme.color.elevated : "transparent"
                                }
                                AppIcon {
                                    anchors.centerIn: parent
                                    name: "edit"
                                    size: Theme.icon.sm
                                    color: Theme.color.textSecondary
                                }
                                MouseArea {
                                    id: renameMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const sid = savedRow._model.id
                                        const oldName = savedRow._model.name
                                        root.close()
                                        Qt.callLater(function() {
                                            AppState.openModal("naming", {
                                                title: qsTr("Rename schedule"),
                                                placeholder: qsTr("Schedule name"),
                                                confirmText: qsTr("Rename"),
                                                initialValue: oldName,
                                                onConfirm: function(n) {
                                                    ScheduleService.rename(sid, n)
                                                }
                                            })
                                        })
                                    }
                                }
                            }

                            // Delete icon
                            Item {
                                width: 24; height: 24
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.radius.sm
                                    color: delMa.containsMouse
                                         ? Qt.darker(Theme.color.live, 1.6)
                                         : "transparent"
                                }
                                AppIcon {
                                    anchors.centerIn: parent
                                    name: "trash"
                                    size: Theme.icon.sm
                                    color: delMa.containsMouse
                                         ? Theme.color.live
                                         : Theme.color.textSecondary
                                }
                                MouseArea {
                                    id: delMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const sid = savedRow._model.id
                                        const sname = savedRow._model.name
                                        root.close()
                                        Qt.callLater(function() {
                                            AppState.openModal("confirm", {
                                                title: qsTr("Delete schedule?"),
                                                body:  qsTr("Delete \"") + sname + qsTr("\"? This cannot be undone."),
                                                confirmText: qsTr("Delete"),
                                                onConfirm: function() {
                                                    ScheduleService.deleteSaved(sid)
                                                }
                                            })
                                        })
                                    }
                                }
                            }
                        }

                        // Row click → load. Anchors stop before the actions so
                        // clicks on the icons aren't intercepted as "load".
                        MouseArea {
                            id: rowMa
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.right: actions.left
                            anchors.rightMargin: Theme.space.sm
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                ScheduleService.load(savedRow._model.id)
                                root.close()
                            }
                        }
                    }
                }
            }

            // Empty state.
            Item {
                visible: ScheduleService.savedSchedules.length === 0
                width: contents.width
                height: visible ? 32 : 0
                Text {
                    anchors.centerIn: parent
                    text: qsTr("No saved schedules")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }

            // Separator before action items.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.color.borderSubtle
            }

            // ── Save (update loaded row) — only when a schedule is loaded ──
            ActionItem {
                visible: ScheduleService.loadedScheduleId > 0
                iconName: "save"
                label: qsTr("Save") + (ScheduleService.isDirty ? "  •" : "")
                emphasize: ScheduleService.isDirty
                onTriggered: {
                    ScheduleService.saveCurrent()
                    root.close()
                }
            }

            // ── Save as new (always available) ─────────────────────────
            ActionItem {
                iconName: "copy"
                label: ScheduleService.loadedScheduleId > 0
                     ? qsTr("Save as new…")
                     : qsTr("Save current as…")
                onTriggered: {
                    root.close()
                    Qt.callLater(function() {
                        AppState.openModal("naming", {
                            title:       qsTr("Save schedule as"),
                            placeholder: qsTr("e.g., Sunday AM - June 5"),
                            confirmText: qsTr("Save"),
                            onConfirm: function(name) {
                                if (name && name.length > 0) {
                                    ScheduleService.saveAs(name)
                                }
                            }
                        })
                    })
                }
            }

            // ── Close loaded — only when loaded ────────────────────────
            ActionItem {
                visible: ScheduleService.loadedScheduleId > 0
                iconName: "x"
                label: qsTr("Close loaded schedule")
                onTriggered: {
                    ScheduleService.closeLoaded()
                    root.close()
                }
            }

            // ── New empty schedule ─────────────────────────────────────
            ActionItem {
                iconName: "plus"
                label: qsTr("New empty schedule")
                onTriggered: {
                    ScheduleService.clearAll()
                    AppState.clearScheduleSelection()
                    AppState.liveScheduleIndex = -1
                    AppState.libraryLiveActive = false
                    AppState.clearLibraryPreview()
                    root.close()
                }
            }
        }
    }

    // Inline component — keeps the action-item markup tight without leaking
    // a separate file into the qrc index. Lives in the file scope so each
    // declaration above stays a one-liner instead of a 20-line Item block.
    component ActionItem : Item {
        id: ai
        property string iconName: ""
        property string label: ""
        property bool   emphasize: false
        signal triggered()

        width: parent ? parent.width : 0
        height: visible ? 32 : 0

        Rectangle {
            anchors.fill: parent
            radius: Theme.radius.sm
            color: aiMa.containsMouse ? Theme.color.overlay : "transparent"

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.md

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: ai.iconName
                    size: Theme.icon.sm
                    color: Theme.color.textSecondary
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ai.label
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: ai.emphasize ? Theme.font.weightMedium
                                              : Theme.font.weightRegular
                }
            }
            MouseArea {
                id: aiMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ai.triggered()
            }
        }
    }
}
