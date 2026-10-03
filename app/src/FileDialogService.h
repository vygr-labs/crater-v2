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
    //
    // Remembering the folder (both open pickers): pass a `rememberKey` and
    // the picker opens where the last pick under that key came from, and
    // saves the new folder after a pick. `fallbackDir` is where it opens the
    // first time (or when the remembered folder is gone). Either one that
    // doesn't exist on disk is skipped, so callers can pass a likely
    // location ("where EasyWorship keeps its data") without checking.
    Q_INVOKABLE QString chooseOpenFile(QString title, QStringList nameFilters,
                                       QString rememberKey = {},
                                       QString fallbackDir = {});

    // Multi-select variant. Returns the selected paths, or an empty list
    // if the user cancelled. Used by the Media tab "+" button to import
    // multiple images / videos in one go.
    //
    // Initial directory is PicturesLocation (more useful for media than
    // DocumentsLocation) — that's the only behavior difference from
    // chooseOpenFile.
    Q_INVOKABLE QStringList chooseOpenFiles(QString title, QStringList nameFilters,
                                            QString rememberKey = {},
                                            QString fallbackDir = {});

    // suggestedName is the default filename shown in the dialog; the
    // initial directory is the user's Documents folder unless the
    // caller passes a path-bearing suggested name.
    Q_INVOKABLE QString chooseSaveFile(QString title,
                                       QString suggestedName,
                                       QStringList nameFilters);

    // Folder picker. Returns the chosen directory, or an empty string if
    // the user cancelled. Starts in Documents. Used by bulk theme export,
    // which writes one bundle per theme into the chosen folder.
    Q_INVOKABLE QString chooseDirectory(QString title);

    // True when something already exists at `path`. Lets a batch export
    // pick a free file name instead of silently replacing a file.
    Q_INVOKABLE bool pathExists(QString path) const;

private:
    // The folder to open in: remembered, then fallback, then `standard`.
    static QString startDir(const QString& rememberKey, const QString& fallbackDir,
                            const QString& standard);
    // Save the folder `pickedPath` lives in under `rememberKey`.
    static void rememberDir(const QString& rememberKey, const QString& pickedPath);
};

}  // namespace crater
