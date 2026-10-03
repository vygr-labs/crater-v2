import QtQuick
import QtQuick.Controls

// Compact strip shown at the foot of a list while it has checked rows:
// "N selected", Select all, Clear, then that list's bulk actions. Shared by
// the four library tabs and the schedule so the bar reads the same wherever
// the operator multi-selects.
//
// `actions` rows use the PopoverMenu item shape (subset):
//   { label, iconName, destructive?, enabled?, action?, submenu? }
// A row with a `submenu` opens it as a menu anchored on the button (theme
// pickers, collections). Labels collapse to icon-only buttons with a hover
// tooltip when the pane is too narrow to fit them.
Rectangle {
    id: root

    property int  count: 0
    // Checked rows the current search / filter hides (library tabs only).
    property int  hiddenCount: 0
    // False once every visible row is checked, which dims Select all.
    property bool canSelectAll: true
    property var  actions: []

    signal selectAllClicked()
    signal clearClicked()

    implicitHeight: 32
    color: Theme.color.raised

    // Swallow clicks on the bar's empty stretches so they don't reach a
    // row or tile underneath.
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // Full-label width of every button, measured off-screen, decides when
    // the labels have to go.
    Row {
        id: measureRow
        visible: false
        Repeater {
            model: [qsTr("Select all"), qsTr("Clear")]
                .concat(root.actions.map(function(a) { return a.label || "" }))
            Text {
                required property var modelData
                text: modelData
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }
    }
    readonly property int _buttonCount: 2 + root.actions.length
    readonly property real _labelledWidth:
        countText.implicitWidth + Theme.space.md * 2
        + measureRow.implicitWidth
        + _buttonCount * (Theme.icon.sm + 4 + Theme.space.sm * 2 + 2)
        + Theme.space.md
    readonly property bool _compact: width < _labelledWidth

    Text {
        id: countText
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.md
        anchors.right: buttons.left
        anchors.rightMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        text: root.hiddenCount > 0
                ? qsTr("%1 selected (%2 hidden)").arg(root.count).arg(root.hiddenCount)
                : qsTr("%1 selected").arg(root.count)
        color: Theme.color.brand
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        font.weight: Theme.font.weightMedium
        elide: Text.ElideRight
    }

    component BarButton: Rectangle {
        id: btn
        property string label: ""
        property string iconName: ""
        property bool   destructive: false
        property bool   showLabel: true
        signal activated()

        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        height: 24
        width: btnRow.implicitWidth + Theme.space.sm * 2
        radius: 0
        opacity: enabled ? 1.0 : 0.4
        color: !btn.enabled ? "transparent"
             : btnMa.containsMouse ? (btn.destructive ? Theme.color.liveSubtle
                                                      : Theme.color.overlay)
                                   : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

        Row {
            id: btnRow
            anchors.centerIn: parent
            spacing: 4
            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: btn.iconName.length > 0
                name: btn.iconName
                size: Theme.icon.sm
                color: btn.destructive ? Theme.color.live
                     : btnMa.containsMouse ? Theme.color.textPrimary
                                           : Theme.color.textSecondary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: btn.showLabel
                text: btn.label
                color: btn.destructive ? Theme.color.live
                     : btnMa.containsMouse ? Theme.color.textPrimary
                                           : Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }

        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: btn.activated()
        }

        ToolTip.visible: !btn.showLabel && btnMa.containsMouse
        ToolTip.text:    btn.label
        ToolTip.delay:   400
    }

    Row {
        id: buttons
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.sm
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        spacing: 2

        BarButton {
            label: qsTr("Select all")
            iconName: "check"
            showLabel: !root._compact
            enabled: root.canSelectAll
            onActivated: root.selectAllClicked()
        }
        BarButton {
            label: qsTr("Clear")
            iconName: "x"
            showLabel: !root._compact
            onActivated: root.clearClicked()
        }

        Rectangle {
            visible: root.actions.length > 0
            anchors.verticalCenter: parent.verticalCenter
            width: 1; height: 14
            color: Theme.color.borderSubtle
        }

        Repeater {
            model: root.actions
            delegate: BarButton {
                id: actionBtn
                required property var modelData
                label: modelData.label || ""
                iconName: modelData.iconName || ""
                destructive: modelData.destructive === true
                enabled: modelData.enabled !== false
                showLabel: !root._compact
                onActivated: {
                    const sub = modelData.submenu
                    if (sub && sub.length > 0) {
                        AppState.openContextMenuAt(actionBtn, 0, actionBtn.height + 4, sub,
                                                   { menuWidth: 220 })
                    } else if (typeof modelData.action === "function") {
                        modelData.action()
                    }
                }
            }
        }
    }
}
