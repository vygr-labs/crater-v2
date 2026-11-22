// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

import QtQuick
import QtQuick.Layouts

// Small uppercase label that opens a logical group of settings rows.
// Pass `first: true` for the first header in a pane so it sits flush
// against the pane's top margin instead of adding another section break.
Text {
    id: root

    property string title: ""
    property bool   first: false

    Layout.fillWidth: true
    Layout.topMargin:    root.first ? 0 : Theme.space.xl
    Layout.bottomMargin: Theme.space.sm

    text: root.title.toUpperCase()
    color: Theme.color.textTertiary
    font.family: Theme.font.family
    font.pixelSize: Theme.font.microSize
    font.weight: Theme.font.weightSemiBold
    font.letterSpacing: 1.0
}
