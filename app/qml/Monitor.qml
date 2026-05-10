import QtQuick

// 16:9 monitor frame for preview/live output thumbnails.
// `monitorState`: "idle" | "preview" | "live" — controls border color.
Item {
    id: root

    property string monitorState: "idle"
    property string caption: ""
    property string subCaption: ""

    implicitWidth: 320
    implicitHeight: frame.height + captionColumn.height + Theme.space.sm

    Rectangle {
        id: frame

        width: parent.width
        height: width * 9 / 16
        radius: Theme.radius.md
        color: "#000"
        border.width: 1.5
        border.color: root.monitorState === "live"    ? Theme.color.live
                    : root.monitorState === "preview" ? Theme.color.preview
                                                      : Theme.color.borderStrong
        antialiasing: true

        Behavior on border.color { ColorAnimation { duration: Theme.motion.normal } }

        // Inner gradient stands in for video — replaced by real QSGTexture later.
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1.5
            radius: parent.radius - 1
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#0d0d12" }
                GradientStop { position: 1.0; color: "#050508" }
            }
        }

        // Letterboxed caption preview
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.82
            text: root.caption.length > 0 ? root.caption : qsTr("No content")
            color: root.caption.length > 0 ? Theme.color.textPrimary : Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Math.max(14, frame.height * 0.18)
            font.weight: Theme.font.weightLight
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            maximumLineCount: 3
            elide: Text.ElideRight
            opacity: 0.92
        }

        // Aspect-ratio chip in corner — looks like real broadcast software
        Rectangle {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 6
            width: aspectLabel.implicitWidth + 8
            height: 14
            radius: 2
            color: "#00000080"

            Text {
                id: aspectLabel
                anchors.centerIn: parent
                text: "16:9 · 1920×1080"
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: 8
            }
        }
    }

    Column {
        id: captionColumn
        anchors.top: frame.bottom
        anchors.topMargin: Theme.space.sm
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 2

        Text {
            text: root.caption
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightMedium
            elide: Text.ElideRight
            width: parent.width
        }
        Text {
            visible: root.subCaption.length > 0
            text: root.subCaption
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            elide: Text.ElideRight
            width: parent.width
        }
    }
}
