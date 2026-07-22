#pragma once

#include "crater/value/Collection.h"

#include <QList>
#include <QObject>
#include <QString>

#include <memory>

namespace crater {

namespace db { class Connection; }

// Song collections — user-created named groupings of songs (many-to-many).
//
// Backed by the collections + collection_songs tables in songs.sqlite (the same
// DB SongService owns, via its own connection). Favorites are NOT collections —
// they remain an is_favorite flag on songs; this service is only the named
// collections the sidebar's "My Collections" group shows.
//
// Every mutation emits collectionsChanged() so QML bindings — the sidebar group
// list and SongsTab's collection filter — re-read. All methods are sync
// (ARCHITECTURE.md §3): collections are few and every query is indexed.
class CollectionService : public QObject
{
    Q_OBJECT

    // Every collection with its derived song count, ordered by creation time.
    // QML binds this in the sidebar; reading it also establishes the reactive
    // dependency that re-runs SongsTab's collection filter on membership edits.
    Q_PROPERTY(QList<crater::Collection> collections READ collections NOTIFY collectionsChanged)

public:
    explicit CollectionService(QObject* parent = nullptr);
    ~CollectionService() override;

    QList<crater::Collection> collections();

    // Create an empty collection. Returns the new id, or 0 on failure/empty name.
    Q_INVOKABLE qint64 create(QString name);

    // Rename. Returns true on success.
    Q_INVOKABLE bool rename(qint64 id, QString name);

    // Deep-copy a collection (name becomes "<name> copy", same membership).
    // Returns the new id, or 0 on failure.
    Q_INVOKABLE qint64 duplicate(qint64 id);

    // Delete the collection. Membership rows cascade away; songs are untouched.
    Q_INVOKABLE void destroy(qint64 id);

    // Add / remove a song. addSong is idempotent (INSERT OR IGNORE); new members
    // append to the end (max sort_order + 1).
    Q_INVOKABLE void addSong(qint64 collectionId, qint64 songId);
    Q_INVOKABLE void removeSong(qint64 collectionId, qint64 songId);

    // Ordered song ids in a collection — the set SongsTab filters against.
    Q_INVOKABLE QList<qint64> songIdsFor(qint64 collectionId);

signals:
    void collectionsChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
