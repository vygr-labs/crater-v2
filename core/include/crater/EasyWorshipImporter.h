#pragma once

#include <QFuture>
#include <QObject>
#include <QString>
#include <QStringList>

namespace crater {

// Imports a song library from an EasyWorship 6 / 7 installation.
//
// EasyWorship 6/7 keep songs across two SQLite files — Songs.db (the `song`
// table: title / author / copyright / ccli_no) and SongWords.db (the `word`
// table: lyrics as RTF). This importer reads both, converts each RTF lyric
// blob to plain text (crater::rtf), splits it into labeled sections, and
// writes songs + song_sections + the songs_fts index straight into the app's
// songs.sqlite — one transaction, on a worker thread.
//
// The two-step protocol lets the operator decide what to do about overlap
// before committing:
//   1. analyze(files)      -> emits analyzed(totalSongs, duplicateCount)
//   2. run(files, skip)    -> emits progress(...), then completed(imported, skipped)
//
// QML consumers drive this entirely through the signals below. It is NOT a
// crater-core service (no singleton catalog entry) — it is a one-shot
// operation object, modeled on ElectronDataImporter. It holds no state
// between calls, so a single instance is safely reused for every import.
class EasyWorshipImporter : public QObject
{
    Q_OBJECT

public:
    explicit EasyWorshipImporter(QObject* parent = nullptr);
    ~EasyWorshipImporter() override;

    // Probe the chosen files: confirm they are an EasyWorship Songs.db +
    // SongWords.db pair, count importable songs, and count how many collide
    // (title + author, case-insensitive) with songs already in the library.
    // `dbFiles` is the raw multi-select result — order does not matter, each
    // file is identified by its table schema. Result via analyzed() or
    // failed(). Runs on a worker thread.
    Q_INVOKABLE void analyze(QStringList dbFiles);

    // Import the library. When `skipDuplicates` is true, songs whose title +
    // author already exist in the library are not inserted. Progress via
    // progress(); result via completed() or failed(). Runs on a worker thread.
    Q_INVOKABLE void run(QStringList dbFiles, bool skipDuplicates);

signals:
    void progress(int percent, QString stage);
    void analyzed(int totalSongs, int duplicateCount);
    void completed(int importedCount, int skippedCount);
    void failed(QString reason);

private:
    // Handle to the in-flight worker (analyze or run). The destructor waits on
    // it so a still-running import can't touch this object after it is freed —
    // e.g. when the operator quits the app mid-import.
    QFuture<void> m_task;
};

}  // namespace crater
