#include "FileDialogService.h"

#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QStandardPaths>

namespace crater {

FileDialogService::FileDialogService(QObject* parent)
    : QObject(parent)
{}

QString FileDialogService::chooseOpenFile(QString title, QStringList nameFilters)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    const QString filter     = nameFilters.join(QStringLiteral(";;"));
    return QFileDialog::getOpenFileName(
        /*parent=*/nullptr,
        title,
        initialDir,
        filter);
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

}  // namespace crater
