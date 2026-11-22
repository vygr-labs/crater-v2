// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

import QtQuick
import Crater

// Draws the live overlay (LiveMessages) over whatever hosts it. Mounted in
// ProjectionScene's canvas stage, so the projector, every mirror output and
// NDI each get one, and in the Live monitors so the operator sees what the
// audience sees. The Messages dialog's preview mounts one with its inputs
// bound to the settings it has not shown yet.
//
// Every size is a fraction of this item's own size, so the same layer reads
// right on a 1920x1080 canvas and in a 300 px preview. Digits shrink to fit
// the width rather than wrap, which matters on a 4:3 or portrait canvas and
// once an hour appears on the clock.
Item {
    id: layer

    // The live singleton by default; the dialog's preview overrides them.
    property bool   shown:      LiveMessages.active
    property string text:       LiveMessages.text
    property string caption:    LiveMessages.captionText
    property bool   isMessage:  LiveMessages.showingMessage
    property string position:   LiveMessages.position
    property string background: LiveMessages.background

    readonly property real _h: height

    opacity: shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.InOutCubic }
    }

    // "dim" leaves the content faintly visible, "solid" covers it.
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: layer.background === "solid" ? 1
               : layer.background === "dim"   ? 0.6
                                              : 0
    }

    Column {
        id: block
        width: parent.width * 0.86
        x: (parent.width - width) / 2
        y: layer.position === "top"    ? layer._h * 0.08
         : layer.position === "bottom" ? layer._h * 0.92 - height
                                       : (layer._h - height) / 2
        spacing: layer._h * 0.015

        // Digits sit on one line and shrink to the width. Prose wraps inside
        // a fixed box and shrinks to fit it, aligned to the edge it sits on.
        Text {
            id: primary
            width: parent.width
            height: layer.isMessage
                    ? layer._h * (layer.position === "center" ? 0.7 : 0.36)
                    : contentHeight
            visible: text.length > 0
            text: layer.text
            color: "#ffffff"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: !layer.isMessage           ? Text.AlignVCenter
                             : layer.position === "top"    ? Text.AlignTop
                             : layer.position === "bottom" ? Text.AlignBottom
                                                           : Text.AlignVCenter
            font.family: Theme.font.family
            font.weight: layer.isMessage ? Theme.font.weightSemiBold : Theme.font.weightBold
            font.pixelSize: Math.max(8, layer._h * (layer.isMessage
                                                    ? (layer.position === "center" ? 0.11 : 0.085)
                                                    : (layer.position === "center" ? 0.24 : 0.13)))
            // Even-width digits, so a ticking countdown does not shuffle
            // sideways every second.
            font.features: { "tnum": 1 }
            fontSizeMode: layer.isMessage ? Text.Fit : Text.HorizontalFit
            minimumPixelSize: Math.max(8, layer._h * 0.03)
            wrapMode: layer.isMessage ? Text.WordWrap : Text.NoWrap
            elide: Text.ElideRight
            // Keeps white text readable when there is no background behind it.
            style: Text.Outline
            styleColor: "#000000"
        }

        Text {
            width: parent.width
            visible: text.length > 0
            text: layer.caption
            color: "#f0f0f0"
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.font.family
            font.weight: Theme.font.weightMedium
            font.pixelSize: Math.max(8, layer._h * 0.05)
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            style: Text.Outline
            styleColor: "#000000"
        }
    }
}
