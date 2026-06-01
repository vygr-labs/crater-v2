#pragma once

#include <QObject>
#include <QString>

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
class ClipboardService : public QObject
{
    Q_OBJECT

public:
    explicit ClipboardService(QObject* parent = nullptr);

    // Replace the clipboard contents with `text`. No-op on empty text so a
    // mis-fired copy (nothing selected) doesn't wipe whatever the operator
    // had on the clipboard already.
    Q_INVOKABLE void setText(const QString& text);
};

}  // namespace crater
