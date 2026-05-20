#pragma once

#include "crater/value/Song.h"

#include <QFuture>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariantList>

#include <memory>

namespace crater {

// Song library service — CRUD + FTS5 search over songs.sqlite.
//
// Threading: main-thread only for reads/writes (same model as BibleService).
// `rebuildFtsIndex()` is the one async path, running on a QtConcurrent worker
// with its own SQLite connection.
//
// Caching: `allSongs` results are cached in-memory. Cache invalidates on any
// mutation (create/update/destroy/toggleFavorite); the `allSongsChanged` signal
// fires so QML bindings re-read the property.
class SongService : public QObject
{
    Q_OBJECT

    // Metadata-only list of every song. QML binds `model: SongService.allSongs`.
    // Sections are NOT included here — call fetchSong(id) for the full record.
    Q_PROPERTY(QList<crater::Song> allSongs READ allSongs NOTIFY allSongsChanged)

public:
    explicit SongService(QObject* parent = nullptr);
    ~SongService() override;

    QList<crater::Song> allSongs();

    // Full song with sections (lines, kind, sort_order populated). Returns
    // empty Song on miss.
    Q_INVOKABLE crater::Song fetchSong(qint64 id);

    // FTS5 search across title + author + lyrics. Returns metadata-only Songs
    // (no sections). Capped at 100 hits.
    Q_INVOKABLE QList<crater::Song> search(QString query);

    // Creates a song with metadata only (no sections). Used by the "+ New Song"
    // flow that names the song first and opens an empty editor afterwards.
    // Returns new song id, or 0 on failure.
    Q_INVOKABLE qint64 create(QString title, QString author, QString ccli = {});

    // Creates a song WITH sections in one transaction — the path the song
    // editor uses when the operator clicks Save on a brand-new song. Sections
    // are a QVariantList of objects: { label: QString, kind: QString optional,
    // lines: QStringList }. Missing/unrecognized `kind` defaults to "other" so
    // the schema CHECK constraint passes. Returns the new song id (0 on failure).
    Q_INVOKABLE qint64 createWithSections(QString title, QString author, QString ccli,
                                          qint64 themeId, QVariantList sections);

    // Updates an existing song's title, author, ccli, themeId, and sections.
    // Sections are replaced wholesale (delete-then-insert under one transaction).
    // themeId == 0 clears the per-song override (NULL in DB). Returns true on
    // success. FTS row is refreshed so search reflects the new lyrics immediately.
    Q_INVOKABLE bool update(qint64 id, QString title, QString author, QString ccli,
                            qint64 themeId, QVariantList sections);

    Q_INVOKABLE void destroy(qint64 id);
    Q_INVOKABLE void toggleFavorite(qint64 id);

    // Deep-copies an existing song (title becomes "<title> (copy)", favorite
    // resets to false, timestamps reset to now). Sections are copied verbatim
    // preserving sort_order. Returns the new song id, or 0 on failure.
    Q_INVOKABLE qint64 duplicate(qint64 id);

    // Drops and rebuilds songs_fts from songs + song_sections.
    Q_INVOKABLE QFuture<void> rebuildFtsIndex();

    // Re-reads the library after an external writer (e.g. the EasyWorship
    // importer) has modified songs.sqlite directly. Drops the cached
    // allSongs() result and emits allSongsChanged() so QML bindings refresh.
    Q_INVOKABLE void reload();

signals:
    void allSongsChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void invalidateCache();
};

}  // namespace crater
