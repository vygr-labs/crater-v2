#include "FileDialogService.h"

#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>

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
    const QString filter     = nameFilters.join(QStringLiteral(";;"));
    const QString picked = QFileDialog::getOpenFileName(
        /*parent=*/nullptr,
        title,
        initialDir,
        filter);
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
    const QString filter = nameFilters.join(QStringLiteral(";;"));
    const QStringList picked = QFileDialog::getOpenFileNames(
        /*parent=*/nullptr,
        title,
        initialDir,
        filter);
    if (!picked.isEmpty()) rememberDir(rememberKey, picked.first());
    return picked;
}

QString FileDialogService::chooseSaveFile(QString title,
                                          QString suggestedName,
                                          QStringList nameFilters)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    const QString initialPath = QDir(initialDir).filePath(suggestedName);
    const QString filter      = nameFilters.join(QStringLiteral(";;"));
    return QFileDialog::getSaveFileName(
        /*parent=*/nullptr,
        title,
        initialPath,
        filter);
}

QString FileDialogService::chooseDirectory(QString title)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    return QFileDialog::getExistingDirectory(
        /*parent=*/nullptr,
        title,
        initialDir);
}

bool FileDialogService::pathExists(QString path) const
{
    return QFileInfo::exists(path);
}

}  // namespace crater
