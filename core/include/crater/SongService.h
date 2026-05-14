#pragma once

#include "crater/value/Song.h"

#include <QFuture>
#include <QList>
#include <QObject>
#include <QString>

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

    // Creates a song. Sections are passed as raw data (QVariantList of objects
    // with label/kind/lines fields) for QML-friendliness. Returns new song id.
    Q_INVOKABLE qint64 create(QString title, QString author, QString ccli = {});

    Q_INVOKABLE void destroy(qint64 id);
    Q_INVOKABLE void toggleFavorite(qint64 id);

    // Deep-copies an existing song (title becomes "<title> (copy)", favorite
    // resets to false, timestamps reset to now). Sections are copied verbatim
    // preserving sort_order. Returns the new song id, or 0 on failure.
    Q_INVOKABLE qint64 duplicate(qint64 id);

    // Drops and rebuilds songs_fts from songs + song_sections.
    Q_INVOKABLE QFuture<void> rebuildFtsIndex();

signals:
    void allSongsChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void invalidateCache();
};

}  // namespace crater
