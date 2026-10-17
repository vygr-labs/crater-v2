#include "FileDialogService.h"

#include <QDebug>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QWindow>

namespace crater {

FileDialogService::FileDialogService(QObject* parent)
    : QObject(parent)
{}

namespace {

QString settingsKey(const QString& rememberKey)
{
    return QStringLiteral("fileDialogs/") + rememberKey;
}

}  // namespace

QString FileDialogService::startDir(const QString& rememberKey, const QString& fallbackDir,
                                    const QString& standard)
{
    if (!rememberKey.isEmpty()) {
        const QString last = QSettings().value(settingsKey(rememberKey)).toString();
        if (!last.isEmpty() && QFileInfo(last).isDir()) return last;
    }
    if (!fallbackDir.isEmpty() && QFileInfo(fallbackDir).isDir()) return fallbackDir;
    return standard;
}

void FileDialogService::setOwner(QWindow* owner)
{
    m_owner = owner;
}

// A picker with no owner is a free-floating window. Windows can open it
// behind the projection window, which stays on top of its screen, or behind
// the console, and the console stays clickable underneath, so the operator
// sees a button that does nothing. Owned by the console, the picker opens
// over it and blocks it until it closes.
bool FileDialogService::run(QFileDialog& dialog, const char* kind)
{
    if (m_open) {
        qWarning() << "FileDialog:" << kind << "ignored, a picker is already open";
        return false;
    }
    dialog.setWindowModality(Qt::ApplicationModal);
    if (m_owner) {
        dialog.winId();   // creates windowHandle() so it can take an owner
        if (QWindow* handle = dialog.windowHandle()) handle->setTransientParent(m_owner);
    }
    qInfo().noquote() << "FileDialog: opening" << kind << "in" << dialog.directory().path()
                      << (m_owner ? "" : "(no owner window)");
    m_open = true;
    const bool accepted = dialog.exec() == QDialog::Accepted;
    m_open = false;
    qInfo().noquote() << "FileDialog:" << kind
                      << (accepted ? QStringLiteral("picked %1 item(s)").arg(dialog.selectedFiles().size())
                                   : QStringLiteral("cancelled"));
    return accepted;
}

void FileDialogService::rememberDir(const QString& rememberKey, const QString& pickedPath)
{
    if (rememberKey.isEmpty() || pickedPath.isEmpty()) return;
    QSettings().setValue(settingsKey(rememberKey), QFileInfo(pickedPath).absolutePath());
}

QString FileDialogService::chooseOpenFile(QString title, QStringList nameFilters,
                                          QString rememberKey, QString fallbackDir)
{
    const QString initialDir = startDir(rememberKey, fallbackDir,
        QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation));
    QFileDialog dialog(nullptr, title, initialDir, nameFilters.join(QStringLiteral(";;")));
    dialog.setFileMode(QFileDialog::ExistingFile);
    if (!run(dialog, "open file")) return {};
    const QString picked = dialog.selectedFiles().value(0);
    rememberDir(rememberKey, picked);
    return picked;
}

QStringList FileDialogService::chooseOpenFiles(QString title, QStringList nameFilters,
                                               QString rememberKey, QString fallbackDir)
{
    // PicturesLocation is empty on minimal Linux desktops; fall back to
    // DocumentsLocation so the dialog opens *somewhere* rather than at the
    // filesystem root.
    QString initialDir = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
    if (initialDir.isEmpty()) {
        initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    }
    initialDir = startDir(rememberKey, fallbackDir, initialDir);
    QFileDialog dialog(nullptr, title, initialDir, nameFilters.join(QStringLiteral(";;")));
    dialog.setFileMode(QFileDialog::ExistingFiles);
    if (!run(dialog, "open files")) return {};
    const QStringList picked = dialog.selectedFiles();
    if (!picked.isEmpty()) rememberDir(rememberKey, picked.first());
    return picked;
}

QString FileDialogService::chooseSaveFile(QString title,
                                          QString suggestedName,
                                          QStringList nameFilters)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    const QString initialPath = QDir(initialDir).filePath(suggestedName);
    QFileDialog dialog(nullptr, title, initialPath, nameFilters.join(QStringLiteral(";;")));
    dialog.setAcceptMode(QFileDialog::AcceptSave);
    dialog.setFileMode(QFileDialog::AnyFile);
    if (!run(dialog, "save file")) return {};
    return dialog.selectedFiles().value(0);
}

QString FileDialogService::chooseDirectory(QString title)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    QFileDialog dialog(nullptr, title, initialDir);
    dialog.setFileMode(QFileDialog::Directory);
    dialog.setOption(QFileDialog::ShowDirsOnly);
    if (!run(dialog, "choose folder")) return {};
    return dialog.selectedFiles().value(0);
}

bool FileDialogService::pathExists(QString path) const
{
    return QFileInfo::exists(path);
}

}  // namespace crater
