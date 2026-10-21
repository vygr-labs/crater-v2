#pragma once

#include <QObject>
#include <QString>

class QQuickItem;

namespace crater {

// System-clipboard bridge for QML. Wraps QGuiApplication::clipboard()->setText.
//
// Why this lives in the app target (not crater-core):
//   - QClipboard is part of Qt6::Gui (QGuiApplication owns the clipboard).
//   - crater-core's portability rule forbids any GUI module — see
//     ARCHITECTURE.md §1. The same reasoning that keeps FileDialogService
//     (QtWidgets) out of core applies here.
//
// Qt6::Gui is already linked transitively via Qt6::Quick, so this adds no new
// link dependency — only a few lines of glue and one QML singleton.
//
// QML has no built-in clipboard object (TextInput/TextEdit can copy their own
// selection, but there's no general writer), so this small Q_INVOKABLE shim is
// the standard way to put arbitrary text on the clipboard from QML.
//
// Copy fallback (Windows): Qt writes the clipboard through OleSetClipboard,
// and on some PCs that call fails every time (COM error 0x800703f0 or
// 0x80070002 in crater.log). Qt only logs the failure and drops the data, so
// nothing reaches the clipboard. Every copy Crater makes, from a text box's
// Ctrl+C / Ctrl+X, the right-click menu or setText, is checked against the
// clipboard's sequence number afterwards, and if it never moved the text is
// written again through the plain Win32 clipboard calls.
class ClipboardService : public QObject
{
    Q_OBJECT

public:
    explicit ClipboardService(QObject* parent = nullptr);

    // Replace the clipboard contents with `text`. No-op on empty text so a
    // mis-fired copy (nothing selected) doesn't wipe whatever the operator
    // had on the clipboard already.
    Q_INVOKABLE void setText(const QString& text);

    // Copy or cut a TextInput / TextEdit's selection, as its own copy() /
    // cut() would, with the fallback above. For the right-click menu.
    Q_INVOKABLE void copySelection(QQuickItem* textBox);
    Q_INVOKABLE void cutSelection(QQuickItem* textBox);

protected:
    // Installed on the application (Windows only): catches Ctrl+C / Ctrl+X
    // in a text box and checks the copy once the box has handled the key.
    // A selected box whose own Keys handler takes Ctrl+C for something else
    // must declare `readonly property bool ownsCopyKey: true`, or the
    // check would see no copy and write the selection itself.
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    void copyOrCut(QQuickItem* textBox, const char* method);
};

}  // namespace crater
