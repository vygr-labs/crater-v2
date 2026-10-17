import QtQuick

// Progress for a bulk theme export. Each theme goes through
// ThemeService.exportThemeAsync in turn, so a batch with video backgrounds
// no longer freezes the window until the last file is written.
//
// Opened from ThemesTab via:
//   AppState.openModal("bulkExportThemes", {
//       jobs,     // [{ id, name, path }], file names already resolved
//       onDone    // function(exported, failedNames, stopped, lastError)
//   })
ModalShell {
    id: root

    dialogWidth: 460
    dialogHeight: 210
    title: qsTr("Export themes")
    showCloseButton: false

    readonly property var _jobs: AppState.modalProps.jobs || []
    property int  _index: 0
    property int  _exported: 0
    property var  _failed: []
    property string _lastError: ""
    property bool _stopping: false

    readonly property var _current: _index < _jobs.length ? _jobs[_index] : null

    function _startNext() {
        if (root._stopping || root._index >= root._jobs.length) {
            root._finish()
            return
        }
        const job = root._jobs[root._index]
        if (ThemeService.exportThemeAsync(job.id, job.path, [])) return
        // Could not start this one (theme gone, nothing to bundle): note it
        // and carry on with the rest.
        root._failed = root._failed.concat([job.name])
        root._lastError = ThemeService.lastExportError() || ""
        root._index++
        Qt.callLater(root._startNext)
    }

    function _finish() {
        const cb = AppState.modalProps.onDone
        const exported = root._exported
        const failed = root._failed
        const stopped = root._stopping
        const error = root._lastError
        AppState.closeModal()
        if (typeof cb === "function") cb(exported, failed, stopped, error)
    }

    // Closing would leave no way to see how far the batch got, so the
    // backdrop, Escape and X wait. Stop ends it early instead.
    function requestClose() { }

    Connections {
        target: ThemeService
        function onExportFinished(ok, cancelled, error, filePath) {
            if (cancelled) {
                root._finish()
                return
            }
            if (ok) {
                root._exported++
            } else {
                root._failed = root._failed.concat([root._jobs[root._index].name])
                root._lastError = error || ""
            }
            root._index++
            // Start the next one after this signal returns, not from
            // inside the finished export's own completion.
            Qt.callLater(root._startNext)
        }
    }

    Component.onCompleted: Qt.callLater(root._startNext)

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        Column {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.xs

            Text {
                width: parent.width
                text: qsTr("Exporting %1 of %2")
                      .arg(Math.min(root._index + 1, root._jobs.length)).arg(root._jobs.length)
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 1
                font.weight: Theme.font.weightSemiBold
            }
            Text {
                width: parent.width
                text: root._current ? root._current.name : ""
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                elide: Text.ElideRight
            }

            Item { width: 1; height: Theme.space.sm }

            // The whole batch: finished themes plus the share of the one
            // being written.
            Rectangle {
                width: parent.width
                height: 4
                radius: Theme.radius.pill
                color: Theme.color.borderSubtle
                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    color: Theme.color.brand
                    width: root._jobs.length === 0 ? 0
                         : parent.width * Math.min(1, (root._index
                               + (ThemeService.exportBusy ? ThemeService.exportProgress : 0))
                               / root._jobs.length)
                    Behavior on width { NumberAnimation { duration: Theme.motion.instant } }
                }
            }
            Text {
                width: parent.width
                text: ThemeService.exportBusy ? ThemeService.exportProgressText : ""
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                elide: Text.ElideRight
            }
        }

        GhostButton {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            text: root._stopping ? qsTr("Stopping...") : qsTr("Stop")
            enabled: !root._stopping
            onClicked: {
                root._stopping = true
                // Between two themes nothing is running, and _startNext
                // sees _stopping instead.
                ThemeService.cancelExport()
            }
        }
    }
}
