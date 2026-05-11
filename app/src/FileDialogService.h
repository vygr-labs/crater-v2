#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

namespace crater {

// Native file picker bridge for QML. Wraps QFileDialog::getOpenFileName /
// getSaveFileName — these spawn the OS-native chooser on Windows / macOS /
// Linux (KDE / GNOME), so the operator gets the experience they expect.
//
// Why this lives in the app target (not crater-core):
//   - It depends on Qt6::Widgets (QFileDialog inherits from QDialog).
//   - crater-core's portability rule forbids any GUI module — see
//     ARCHITECTURE.md §1.
//
// Why not QtQuick.Dialogs.FileDialog: the project forbids runtime QML
// modules (thin-exe rule). Linking Qt6::Widgets as a build-time dep is
// fine — it costs ~1 MB on the binary and gives us the native chooser
// without any QML import.
//
// Modal behavior: getOpenFileName / getSaveFileName block until the user
// dismisses the dialog. That's fine here — the theme editor is a full-
// screen workspace; the operator console behind it doesn't need to
// remain responsive while a file picker is open.
class FileDialogService : public QObject
{
    Q_OBJECT

public:
    explicit FileDialogService(QObject* parent = nullptr);

    // Returns the selected file path, or an empty string if the user
    // cancelled. `nameFilters` is a list of Qt-style filter entries
    // ("Crater Theme (*.craterheme)").
    Q_INVOKABLE QString chooseOpenFile(QString title, QStringList nameFilters);

    // Multi-select variant. Returns the selected paths, or an empty list
    // if the user cancelled. Used by the Media tab "+" button to import
    // multiple images / videos in one go.
    //
    // Initial directory is PicturesLocation (more useful for media than
    // DocumentsLocation) — that's the only behavior difference from
    // chooseOpenFile.
    Q_INVOKABLE QStringList chooseOpenFiles(QString title, QStringList nameFilters);

    // suggestedName is the default filename shown in the dialog; the
    // initial directory is the user's Documents folder unless the
    // caller passes a path-bearing suggested name.
    Q_INVOKABLE QString chooseSaveFile(QString title,
                                       QString suggestedName,
                                       QStringList nameFilters);
};

}  // namespace crater
