#pragma once

#include <QFuture>
#include <QMutex>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
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
//   1. analyze(files)            -> analyzed(info)
//   2. run(files, code, name)    -> progress(...), then completed(code, verses)
//
// An imported Bible is stored like a bundled one: canonical English book
// names (so references and translation switching work unchanged), its verses,
// and its rows in the search index. BibleService only learns of it through
// BibleService::libraryChanged, which main.cpp connects to completed/removed.
//
// Removing is offered only for translations Crater didn't ship, found by
// comparing with the bundled bibles.sqlite.
class BibleImporter : public QObject
{
    Q_OBJECT

public:
    explicit BibleImporter(QObject* parent = nullptr);
    ~BibleImporter() override;

    // Reads the files and reports what they hold, as a map:
    //   format, name, code (a free one, suggested from the file), language,
    //   books, verses, skippedBooks (list), booksByPosition (bool).
    // Result via analyzed() or failed(). Runs on a worker thread.
    Q_INVOKABLE void analyze(QStringList files);

    // Imports the files as a new translation called `name` with `code`.
    // Progress via progress(); result via completed() or failed(). Runs on a
    // worker thread.
    Q_INVOKABLE void run(QStringList files, QString code, QString name);

    // Empty when `code` can name a new translation, otherwise why not.
    Q_INVOKABLE QString codeProblem(QString code) const;

    // True for a translation the operator added (one Crater didn't ship).
    Q_INVOKABLE bool isRemovable(QString code) const;

    // Deletes an added translation and its search index rows. Result via
    // removed() or failed(). Runs on a worker thread.
    Q_INVOKABLE void remove(QString code);

signals:
    void analyzed(QVariantMap info);
    void progress(int percent, QString stage);
    void completed(QString code, int verseCount);
    void removed(QString code);
    void failed(QString reason);

private:
    QSet<QString> bundledCodes() const;
    // The files read once for analyze() and reused by run(), since a whole
    // Bible in USFM takes seconds to read.
    std::shared_ptr<const import::ParsedBible> parse(const QStringList& files);

    QMutex                                     m_parsedLock;
    QStringList                                m_parsedFiles;
    std::shared_ptr<const import::ParsedBible> m_parsed;

    mutable QSet<QString> m_bundled;   // uppercased, read once
    mutable bool          m_bundledRead = false;
    // The destructor waits on it, so a running import can't outlive this.
    QFuture<void> m_task;
    // Set on destruction: stops the search index clean-up a removal leaves
    // running in the background.
    std::shared_ptr<std::atomic_bool> m_stop;
};

}  // namespace crater
