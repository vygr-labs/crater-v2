import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ApplicationWindow {
    id: root

    width: 1280
    height: 800
    minimumWidth: 960
    minimumHeight: 600
    visible: true
    title: qsTr("Crater — Operator Console")

    color: "#0b0b0e"

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 12

        Text {
            text: "Crater"
            color: "#e6e6ea"
            font.pixelSize: 64
            font.weight: Font.Light
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: qsTr("Qt 6 / QML scaffold — ready for porting")
            color: "#8a8a92"
            font.pixelSize: 16
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
