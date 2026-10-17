#include "FileDialogService.h"

#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
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
QStringList FileDialogService::run(const char* kind,
                                   const std::function<void(QFileDialog&)>& setup)
{
    if (m_open) {
        qWarning() << "FileDialog:" << kind << "ignored, a picker is already open";
        return {};
    }
    m_open = true;
    auto show = [&](bool qtPicker, qint64* elapsedMs) -> QStringList {
        QFileDialog dialog;
        setup(dialog);
        if (qtPicker) dialog.setOption(QFileDialog::DontUseNativeDialog, true);
        dialog.setWindowModality(Qt::ApplicationModal);
        if (m_owner) {
            dialog.winId();   // creates windowHandle() so it can take an owner
            if (QWindow* handle = dialog.windowHandle()) handle->setTransientParent(m_owner);
        }
        qInfo().noquote() << "FileDialog: opening" << kind << "in" << dialog.directory().path()
                          << (m_owner ? "" : "(no owner window)")
                          << (qtPicker ? "(Qt picker)" : "");
        QElapsedTimer shown;
        shown.start();
        const bool accepted = dialog.exec() == QDialog::Accepted;
        if (elapsedMs) *elapsedMs = shown.elapsed();
        return accepted ? dialog.selectedFiles() : QStringList();
    };

    qint64 elapsed = 0;
    QStringList picked = show(m_useQtPicker, &elapsed);

    // On some PCs the Windows picker fails before it draws, and Qt reports
    // that as a cancel: on one Windows 10 machine every picker "cancelled"
    // 30 to 50 ms after opening, so Import and Export did nothing at all.
    // Nobody opens and cancels a picker in a quarter of a second, so read
    // that as a failure, open Qt's own picker instead, and keep using it
    // for the rest of the session.
    if (picked.isEmpty() && !m_useQtPicker && elapsed < 250) {
        qWarning().noquote() << "FileDialog: the system picker closed after" << elapsed
                             << "ms without being used, switching to Qt's picker";
        m_useQtPicker = true;
        picked = show(true, nullptr);
    }
    m_open = false;
    qInfo().noquote() << "FileDialog:" << kind
                      << (!picked.isEmpty() ? QStringLiteral("picked %1 item(s)").arg(picked.size())
                                            : QStringLiteral("cancelled"));
    return picked;
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
    const QString picked = run("open file", [&](QFileDialog& dialog) {
        dialog.setWindowTitle(title);
        dialog.setDirectory(initialDir);
        dialog.setNameFilters(nameFilters);
        dialog.setFileMode(QFileDialog::ExistingFile);
    }).value(0);
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
    const QStringList picked = run("open files", [&](QFileDialog& dialog) {
        dialog.setWindowTitle(title);
        dialog.setDirectory(initialDir);
        dialog.setNameFilters(nameFilters);
        dialog.setFileMode(QFileDialog::ExistingFiles);
    });
    if (!picked.isEmpty()) rememberDir(rememberKey, picked.first());
    return picked;
}

QString FileDialogService::chooseSaveFile(QString title,
                                          QString suggestedName,
                                          QStringList nameFilters)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    return run("save file", [&](QFileDialog& dialog) {
        dialog.setWindowTitle(title);
        dialog.setDirectory(initialDir);
        dialog.setNameFilters(nameFilters);
        dialog.setAcceptMode(QFileDialog::AcceptSave);
        dialog.setFileMode(QFileDialog::AnyFile);
        dialog.selectFile(suggestedName);
    }).value(0);
}

QString FileDialogService::chooseDirectory(QString title)
{
    const QString initialDir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    return run("choose folder", [&](QFileDialog& dialog) {
        dialog.setWindowTitle(title);
        dialog.setDirectory(initialDir);
        dialog.setFileMode(QFileDialog::Directory);
        dialog.setOption(QFileDialog::ShowDirsOnly);
    }).value(0);
}

bool FileDialogService::pathExists(QString path) const
{
    return QFileInfo::exists(path);
}

}  // namespace crater
