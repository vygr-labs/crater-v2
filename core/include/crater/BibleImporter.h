#pragma once

#include <QMutex>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QThreadPool>
#include <QVariantMap>

#include <atomic>
#include <memory>

namespace crater {

namespace import { struct ParsedBible; }

// Adds a Bible from a file to the shared Bible library, and removes one the
// operator added.
//
// Reads Zefania XML, OpenSong, OSIS, USFM and USX (import/BibleFormats.h).
// USFM and USX come as one file per book, so a Bible in either is the whole
// set of book files chosen together.
//
// Same two-step protocol as EasyWorshipImporter, so the operator sees what
// the file holds and picks its code before anything is written:
//   1. analyze(files)            -> analyzed(request, info)
//   2. run(files, code, name)    -> progress(...), then completed(request, code, verses)
//
// Each call returns a request id that its signals carry, so a dialog can
// ignore the answer to a request it didn't make (one closed mid-import, or a
// removal running from Settings).
//
// An imported Bible is stored like a bundled one: canonical English book
// names (so references and translation switching work unchanged), its verses,
// and its rows in the search index, with translations.source = 'file'.
// BibleService only learns of it through BibleService::libraryChanged, which
// main.cpp connects to completed/removed.
//
// Everything runs one task at a time on a thread of its own, so two writes
// never contend for the library, and the destructor can wait for all of it.
class BibleImporter : public QObject
{
    Q_OBJECT

public:
    explicit BibleImporter(QObject* parent = nullptr);
    ~BibleImporter() override;

    // Reads the files and reports what they hold, as a map:
    //   format, name, code (a free one, suggested from the file), language,
    //   books, verses, skippedBooks (list), ignoredFiles (list),
    //   booksByPosition (bool).
    // Result via analyzed() or failed().
    Q_INVOKABLE int analyze(QStringList files);

    // Imports the files as a new translation called `name` with `code`.
    // Progress via progress(); result via completed() or failed().
    Q_INVOKABLE int run(QStringList files, QString code, QString name);

    // Drops what analyze() read and kept for run(). For a dialog closing
    // without importing.
    Q_INVOKABLE void discardAnalysis();

    // Empty when `code` can name a new translation, otherwise why not.
    Q_INVOKABLE QString codeProblem(QString code) const;

    // True for a translation the operator added from a file.
    Q_INVOKABLE bool isRemovable(QString code) const;

    // Deletes an added translation. Its search index rows are cleared just
    // after, in the background. Result via removed() or failed().
    Q_INVOKABLE int remove(QString code);

signals:
    void analyzed(int request, QVariantMap info);
    void progress(int request, int percent, QString stage);
    void completed(int request, QString code, int verseCount);
    void removed(int request, QString code);
    void failed(int request, QString reason);

private:
    // The files read once for analyze() and reused by run(), since a whole
    // Bible in USFM takes a while to read. Keyed by each file's path, size
    // and modified time; a failed read isn't kept.
    std::shared_ptr<const import::ParsedBible> parse(const QStringList& files);

    QMutex                                     m_parsedLock;
    QString                                    m_parsedKey;
    std::shared_ptr<const import::ParsedBible> m_parsed;

    int         m_nextRequest = 1;
    QThreadPool m_pool;   // one thread: tasks run in order
    // Set on destruction, so a running import or index clean-up stops at
    // its next step instead of holding up the quit.
    std::shared_ptr<std::atomic_bool> m_stop;
};

}  // namespace crater
