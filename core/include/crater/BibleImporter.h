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
// replace() is run() for a code already in use. The new Bible takes over the
// code and the old copy's place in the list, so the default version, the
// profile's order, typed references and schedule rows keep working. The old
// copy isn't deleted: it becomes KJV-OLD, and the profile hides it. It all
// happens in one transaction, so a file that fails leaves the original as it
// was. Schedule rows hold their verses inline and keep them, until a layout
// change rebuilds a passage from the library.
//
// An imported Bible is stored like a bundled one: canonical English book
// names (so references and translation switching work unchanged), its verses,
// and its rows in the search index, with translations.source = 'file'.
// BibleService only learns of it through BibleService::libraryChanged, which
// main.cpp connects to completed, replaced, switchedBack and removed.
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
    //   format, name, code (a free one, suggested from the file), existingCode
    //   (the code the file names, when a translation that can be replaced
    //   already holds it, else empty), language, books, verses, skippedBooks
    //   (list), ignoredFiles (list), booksByPosition (bool).
    // Result via analyzed() or failed().
    Q_INVOKABLE int analyze(QStringList files);

    // Imports the files as a new translation called `name` with `code`.
    // Progress via progress(); result via completed() or failed().
    Q_INVOKABLE int run(QStringList files, QString code, QString name);

    // Imports the files as `code`, replacing the translation that holds it.
    // Result via replaced() or failed(); via completed() if nothing holds
    // the code any more.
    Q_INVOKABLE int replace(QStringList files, QString code, QString name);

    // Puts a replaced copy back under the code it had. The copy holding that
    // code now swaps places with it, so nothing is lost either way. Result
    // via switchedBack() or failed().
    Q_INVOKABLE int switchBack(QString retiredCode);

    // Drops what analyze() read and kept for run(). For a dialog closing
    // without importing.
    Q_INVOKABLE void discardAnalysis();

    // Empty when `code` can name a new translation, otherwise why not.
    Q_INVOKABLE QString codeProblem(QString code) const;

    // True for a translation the operator added from a file, or an old copy
    // an import replaced.
    Q_INVOKABLE bool isRemovable(QString code) const;

    // True when `code` is held by a translation replace() can take over. An
    // old copy can't be replaced: switch it back or remove it.
    Q_INVOKABLE bool canReplace(QString code) const;

    // For the replace confirmation: code, name, verses, and retiredCode, the
    // code the old copy will get. Empty when canReplace() is false.
    Q_INVOKABLE QVariantMap replaceInfo(QString code) const;

    // Deletes an added translation. Its search index rows are cleared just
    // after, in the background. Result via removed() or failed().
    Q_INVOKABLE int remove(QString code);

signals:
    void analyzed(int request, QVariantMap info);
    void progress(int request, int percent, QString stage);
    void completed(int request, QString code, int verseCount);
    void replaced(int request, QString code, QString retiredCode, int verseCount);
    void switchedBack(int request, QString code, QString retiredCode);
    void removed(int request, QString code);
    void failed(int request, QString reason);

private:
    // The files read once for analyze() and reused by run(), since a whole
    // Bible in USFM takes a while to read. Keyed by each file's path, size
    // and modified time; a failed read isn't kept.
    std::shared_ptr<const import::ParsedBible> parse(const QStringList& files);

    int startImport(QStringList files, QString code, QString name, bool replacing);

    QMutex                                     m_parsedLock;
    QString                                    m_parsedKey;
    std::shared_ptr<const import::ParsedBible> m_parsed;
    std::atomic_int                            m_parseGeneration{ 0 };   // bumped by discardAnalysis

    int         m_nextRequest = 1;
    QThreadPool m_pool;   // one thread: tasks run in order
    // Set on destruction, so a running import or index clean-up stops at
    // its next step instead of holding up the quit.
    std::shared_ptr<std::atomic_bool> m_stop;
};

}  // namespace crater
