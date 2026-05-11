#pragma once

#include <QFuture>
#include <QObject>
#include <QString>

namespace crater {

// One-time importer that copies data from electron's bundled SQLite databases
// into our fresh schemas. Runs on a worker thread; emits progress/completed/
// failed back to the main thread via queued signals.
//
// Sentinel file `.imported-v1` in AppDataLocation guards against re-running.
// Idempotent — partial runs are safe to retry because we use `INSERT OR IGNORE`
// keyed on natural keys (translation code, book number, verse coordinates).
//
// Where to find the legacy bibles.sqlite (search order, walking up from the EXE):
//   1. <exe-dir>/legacy/bibles.sqlite                                     (production)
//   2. <repo>/electron/src/assets/default/databases/bibles.sqlite          (dev)
//   3. Returns empty path -> import skipped, warning logged.
//
// NOTE: we deliberately do NOT bundle the 77 MB bibles.sqlite as a Qt resource.
// Embedding a 77 MB blob as a C array would push the EXE past 250 MB of source
// at code-gen time and balloon link times. Production installs will ship the
// file alongside the EXE; dev builds find it in the electron repo.
class ElectronDataImporter : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool needsImport     READ needsImport     CONSTANT)
    Q_PROPERTY(bool legacyAvailable READ legacyAvailable CONSTANT)

public:
    explicit ElectronDataImporter(QObject* parent = nullptr);

    // True iff the sentinel file is absent.
    bool needsImport() const;

    // True iff a legacy bibles.sqlite is findable on disk.
    bool legacyAvailable() const;

    // Runs import on a worker thread. QFuture resolves with `true` on success.
    // Progress/completion is also delivered via the signals below — preferred
    // path for QML consumers.
    Q_INVOKABLE QFuture<bool> run();

signals:
    void progress(int percent, QString stage);
    void completed();
    void failed(QString reason);
};

}  // namespace crater
