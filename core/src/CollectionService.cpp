#include "crater/CollectionService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QDateTime>
#include <QDebug>

namespace crater {

// Impl owns the connection + cached prepared statements. Mirrors SongService —
// its own connection to songs.sqlite (per ARCHITECTURE.md §3, one connection
// per thread; SongService holds a separate one).
struct CollectionService::Impl
{
    db::Connection conn;

    db::Statement selectCollections;  // id, name, COUNT(members)
    db::Statement getName;
    db::Statement insertCollection;
    db::Statement renameCollection;
    db::Statement deleteCollection;
    db::Statement insertMember;
    db::Statement copyMembers;
    db::Statement deleteMember;
    db::Statement selectMemberIds;

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("CollectionService"))
        , selectCollections(conn.prepare(QStringLiteral(
            "SELECT c.id, c.name, COUNT(cs.song_id) AS n "
            "FROM collections c "
            "LEFT JOIN collection_songs cs ON cs.collection_id = c.id "
            "GROUP BY c.id, c.name "
            "ORDER BY c.created_at, c.id")))
        , getName(conn.prepare(QStringLiteral(
            "SELECT name FROM collections WHERE id = ?1 LIMIT 1")))
        , insertCollection(conn.prepare(QStringLiteral(
            "INSERT INTO collections (name, created_at, updated_at) VALUES (?1, ?2, ?3)")))
        , renameCollection(conn.prepare(QStringLiteral(
            "UPDATE collections SET name = ?1, updated_at = ?2 WHERE id = ?3")))
        , deleteCollection(conn.prepare(QStringLiteral(
            "DELETE FROM collections WHERE id = ?1")))
        , insertMember(conn.prepare(QStringLiteral(
            "INSERT OR IGNORE INTO collection_songs (collection_id, song_id, sort_order) "
            "VALUES (?1, ?2, "
            "  (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM collection_songs WHERE collection_id = ?1))")))
        , copyMembers(conn.prepare(QStringLiteral(
            "INSERT INTO collection_songs (collection_id, song_id, sort_order) "
            "SELECT ?1, song_id, sort_order FROM collection_songs WHERE collection_id = ?2")))
        , deleteMember(conn.prepare(QStringLiteral(
            "DELETE FROM collection_songs WHERE collection_id = ?1 AND song_id = ?2")))
        , selectMemberIds(conn.prepare(QStringLiteral(
            "SELECT song_id FROM collection_songs WHERE collection_id = ?1 ORDER BY sort_order, song_id")))
    {}
};

CollectionService::CollectionService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::songsDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "CollectionService: failed to open DB —" << e.message();
    }
}

CollectionService::~CollectionService() = default;

QList<Collection> CollectionService::collections()
{
    QList<Collection> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectCollections;
        stmt.reset();
        while (stmt.step()) {
            Collection c;
            c.id        = stmt.columnInt64(0);
            c.name      = stmt.columnText(1);
            c.songCount = stmt.columnInt(2);
            out.append(std::move(c));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::collections():" << e.message();
    }
    return out;
}

qint64 CollectionService::create(QString name)
{
    if (!m_impl) return 0;
    const QString n = name.trimmed();
    if (n.isEmpty()) return 0;
    try {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        auto& stmt = m_impl->insertCollection;
        stmt.reset();
        stmt.bind(1, n);
        stmt.bind(2, now);
        stmt.bind(3, now);
        stmt.step();
        const qint64 id = m_impl->conn.lastInsertRowId();
        emit collectionsChanged();
        return id;
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::create():" << e.message();
        return 0;
    }
}

bool CollectionService::rename(qint64 id, QString name)
{
    if (!m_impl) return false;
    const QString n = name.trimmed();
    if (n.isEmpty()) return false;
    try {
        auto& stmt = m_impl->renameCollection;
        stmt.reset();
        stmt.bind(1, n);
        stmt.bind(2, QDateTime::currentMSecsSinceEpoch());
        stmt.bind(3, id);
        stmt.step();
        emit collectionsChanged();
        return true;
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::rename():" << e.message();
        return false;
    }
}

qint64 CollectionService::duplicate(qint64 id)
{
    if (!m_impl) return 0;
    try {
        db::Transaction tx(m_impl->conn);

        QString name;
        {
            auto& g = m_impl->getName;
            g.reset();
            g.bind(1, id);
            if (g.step()) name = g.columnText(0);
            g.reset();   // release the read cursor before the writes below
        }
        if (name.isEmpty()) return 0;   // no such collection — tx rolls back

        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        auto& ins = m_impl->insertCollection;
        ins.reset();
        ins.bind(1, name + QStringLiteral(" copy"));
        ins.bind(2, now);
        ins.bind(3, now);
        ins.step();
        const qint64 newId = m_impl->conn.lastInsertRowId();

        auto& cp = m_impl->copyMembers;
        cp.reset();
        cp.bind(1, newId);
        cp.bind(2, id);
        cp.step();

        tx.commit();
        emit collectionsChanged();
        return newId;
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::duplicate():" << e.message();
        return 0;
    }
}

void CollectionService::destroy(qint64 id)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->deleteCollection;
        stmt.reset();
        stmt.bind(1, id);
        stmt.step();
        emit collectionsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::destroy():" << e.message();
    }
}

void CollectionService::addSong(qint64 collectionId, qint64 songId)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->insertMember;
        stmt.reset();
        stmt.bind(1, collectionId);
        stmt.bind(2, songId);
        stmt.step();
        emit collectionsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::addSong():" << e.message();
    }
}

void CollectionService::removeSong(qint64 collectionId, qint64 songId)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->deleteMember;
        stmt.reset();
        stmt.bind(1, collectionId);
        stmt.bind(2, songId);
        stmt.step();
        emit collectionsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::removeSong():" << e.message();
    }
}

QList<qint64> CollectionService::songIdsFor(qint64 collectionId)
{
    QList<qint64> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectMemberIds;
        stmt.reset();
        stmt.bind(1, collectionId);
        while (stmt.step()) out.append(stmt.columnInt64(0));
    } catch (const db::Error& e) {
        qWarning().noquote() << "CollectionService::songIdsFor():" << e.message();
    }
    return out;
}

}  // namespace crater
