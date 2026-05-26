import QtQuick
import QtQuick.Controls

// Drop-in Text replacement that elides on the right by default AND shows
// the full string in a tooltip ONLY when the rendered text is actually
// truncated. Every Text property still works (font, color, wrapMode, etc.)
// — this just adds the hover affordance.
//
// Why gate the tooltip on `truncated`: showing it when the text already
// fits is visual noise. Operators only need the affordance when they
// can't see the whole string.
//
// HoverHandler is the modern Qt 6 passive equivalent of a hover-only
// MouseArea — it reports pointer state without consuming events, so a
// parent MouseArea (the row hover tint on a font list row, say) keeps
// working unchanged.
Text {
    id: root

    elide: Text.ElideRight

    HoverHandler {
        id: hover
        // Disable entirely when the text fits — saves the pointer-tracking
        // overhead on rows that don't need a tooltip and ensures the
        // attached ToolTip never tries to attach.
        enabled: root.truncated
    }

    // 400 ms matches the platform default for tool tips — long enough that
    // a fast cursor sweep across rows doesn't pop a tip on every Text.
    ToolTip.visible: hover.hovered && root.truncated
    ToolTip.text:    root.text
    ToolTip.delay:   400
}
