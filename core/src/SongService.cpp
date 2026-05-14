#include "crater/SongService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QtConcurrent>

#include <optional>

namespace crater {

struct SongService::Impl
{
    db::Connection conn;

    // Cached prepared statements.
    db::Statement selectAllMetadata;
    db::Statement selectSongById;
    db::Statement selectSectionsForSong;
    db::Statement searchFts;
    db::Statement insertSong;
    db::Statement deleteSong;
    db::Statement toggleFavorite;
    db::Statement upsertFtsForSong;
    db::Statement deleteFtsForSong;
    // Two-step deep copy. INSERT...SELECT keeps the data inside SQLite so no
    // QString round-trip is needed for the sections (lines_json can be large).
    db::Statement duplicateSongRow;
    db::Statement duplicateSongSections;

    // Cached allSongs() result. Invalidated on any mutation.
    std::optional<QList<Song>> cachedAll;

    explicit Impl(const QString& path)
        : conn(path)
        // All three SELECT-from-songs paths share the same column layout so
        // readSongRow can be reused. created_at + updated_at sit at columns
        // 7-8; any additional columns (e.g. searchFts's bm25 score) come after.
        , selectAllMetadata(conn.prepare(QStringLiteral(
            "SELECT id, title, author, copyright, ccli, theme_id, is_favorite, "
            "       created_at, updated_at "
            "FROM songs ORDER BY title COLLATE NOCASE")))
        , selectSongById(conn.prepare(QStringLiteral(
            "SELECT id, title, author, copyright, ccli, theme_id, is_favorite, "
            "       created_at, updated_at "
            "FROM songs WHERE id = ?")))
        , selectSectionsForSong(conn.prepare(QStringLiteral(
            "SELECT label, kind, lines_json, sort_order "
            "FROM song_sections WHERE song_id = ? ORDER BY sort_order")))
        , searchFts(conn.prepare(QStringLiteral(
            "SELECT DISTINCT s.id, s.title, s.author, s.copyright, s.ccli, "
            "       s.theme_id, s.is_favorite, s.created_at, s.updated_at, "
            "       bm25(songs_fts) AS score "
            "FROM songs_fts "
            "JOIN songs s ON s.id = songs_fts.rowid "
            "WHERE songs_fts MATCH ? "
            "ORDER BY score ASC LIMIT 100")))
        , insertSong(conn.prepare(QStringLiteral(
            "INSERT INTO songs (title, author, ccli, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?)")))
        , deleteSong(conn.prepare(QStringLiteral(
            "DELETE FROM songs WHERE id = ?")))
        , toggleFavorite(conn.prepare(QStringLiteral(
            "UPDATE songs SET is_favorite = NOT is_favorite, updated_at = ? WHERE id = ?")))
        , upsertFtsForSong(conn.prepare(QStringLiteral(
            "INSERT INTO songs_fts (rowid, title, author, lyrics) "
            "SELECT s.id, s.title, COALESCE(s.author, ''), "
            "       COALESCE((SELECT GROUP_CONCAT(lines_json, ' ') FROM song_sections WHERE song_id = s.id), '') "
            "FROM songs s WHERE s.id = ?")))
        , deleteFtsForSong(conn.prepare(QStringLiteral(
            "DELETE FROM songs_fts WHERE rowid = ?")))
        , duplicateSongRow(conn.prepare(QStringLiteral(
            // Binds (1=nowMs, 2=nowMs, 3=src id). is_favorite resets to 0 so
            // copies don't inherit the favorite flag.
            "INSERT INTO songs "
            "  (title, author, copyright, ccli, theme_id, is_favorite, created_at, updated_at) "
            "SELECT title || ' (copy)', author, copyright, ccli, theme_id, 0, ?, ? "
            "  FROM songs WHERE id = ?")))
        , duplicateSongSections(conn.prepare(QStringLiteral(
            // Binds (1=new id, 2=src id). sort_order preserved verbatim.
            "INSERT INTO song_sections (song_id, label, kind, lines_json, sort_order) "
            "SELECT ?, label, kind, lines_json, sort_order "
            "  FROM song_sections WHERE song_id = ?")))
    {}

    Song readSongRow(db::Statement& s, int idCol = 0)
    {
        Song song;
        song.id         = s.columnInt64(idCol + 0);
        song.title      = s.columnText (idCol + 1);
        song.author     = s.columnText (idCol + 2);
        song.copyright  = s.columnText (idCol + 3);
        song.ccli       = s.columnText (idCol + 4);
        song.themeId    = s.columnInt64(idCol + 5);
        song.isFavorite = s.columnInt  (idCol + 6) != 0;
        song.createdAt  = s.columnInt64(idCol + 7);
        song.updatedAt  = s.columnInt64(idCol + 8);
        return song;
    }
};

SongService::SongService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::songsDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "SongService: failed to open DB —" << e.message();
    }
}

SongService::~SongService() = default;

void SongService::invalidateCache()
{
    if (m_impl) m_impl->cachedAll.reset();
    emit allSongsChanged();
}

QList<Song> SongService::allSongs()
{
    if (!m_impl) return {};
    if (m_impl->cachedAll) return *m_impl->cachedAll;

    QList<Song> out;
    try {
        auto& stmt = m_impl->selectAllMetadata;
        stmt.reset();
        while (stmt.step()) {
            out.append(m_impl->readSongRow(stmt));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::allSongs():" << e.message();
    }
    m_impl->cachedAll = out;
    return out;
}

Song SongService::fetchSong(qint64 id)
{
    Song s;
    if (!m_impl) return s;
    try {
        auto& meta = m_impl->selectSongById;
        meta.reset();
        meta.bind(1, id);
        if (!meta.step()) return s;
        s = m_impl->readSongRow(meta);

        auto& secs = m_impl->selectSectionsForSong;
        secs.reset();
        secs.bind(1, id);
        while (secs.step()) {
            SongSection sec;
            sec.label     = secs.columnText(0);
            sec.kind      = secs.columnText(1);
            sec.sortOrder = secs.columnInt (3);

            const QByteArray linesJson = secs.columnText(2).toUtf8();
            const auto doc = QJsonDocument::fromJson(linesJson);
            if (doc.isArray()) {
                for (const auto& v : doc.array()) {
                    sec.lines.append(v.toString());
                }
            }
            s.sections.append(std::move(sec));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::fetchSong():" << e.message();
    }
    return s;
}

QList<Song> SongService::search(QString query)
{
    QList<Song> out;
    if (!m_impl || query.trimmed().isEmpty()) return out;

    try {
        auto& stmt = m_impl->searchFts;
        stmt.reset();
        stmt.bind(1, query);
        while (stmt.step()) {
            out.append(m_impl->readSongRow(stmt));
        }
    } catch (const db::Error& e) {
        // Partial / malformed FTS queries land here; log quietly.
        qDebug().noquote() << "SongService::search():" << e.message();
    }
    return out;
}

qint64 SongService::create(QString title, QString author, QString ccli)
{
    if (!m_impl) return 0;
    try {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        auto& stmt = m_impl->insertSong;
        stmt.reset();
        stmt.bind(1, title);
        stmt.bind(2, author);
        if (ccli.isEmpty()) stmt.bindNull(3); else stmt.bind(3, ccli);
        stmt.bind(4, nowMs);
        stmt.bind(5, nowMs);
        stmt.step();

        const qint64 id = m_impl->conn.lastInsertRowId();

        // Sync FTS row for the new song (even though sections may be empty).
        auto& fts = m_impl->upsertFtsForSong;
        fts.reset();
        fts.bind(1, id);
        fts.step();

        invalidateCache();
        return id;
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::create():" << e.message();
        return 0;
    }
}

void SongService::destroy(qint64 id)
{
    if (!m_impl) return;
    try {
        db::Transaction tx(m_impl->conn);
        auto& delFts = m_impl->deleteFtsForSong;
        delFts.reset();
        delFts.bind(1, id);
        delFts.step();

        auto& delSong = m_impl->deleteSong;
        delSong.reset();
        delSong.bind(1, id);
        delSong.step();
        tx.commit();

        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::destroy():" << e.message();
    }
}

void SongService::toggleFavorite(qint64 id)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->toggleFavorite;
        stmt.reset();
        stmt.bind(1, QDateTime::currentMSecsSinceEpoch());
        stmt.bind(2, id);
        stmt.step();
        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::toggleFavorite():" << e.message();
    }
}

qint64 SongService::duplicate(qint64 id)
{
    if (!m_impl || id <= 0) return 0;
    try {
        db::Transaction tx(m_impl->conn);
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();

        auto& rowStmt = m_impl->duplicateSongRow;
        rowStmt.reset();
        rowStmt.bind(1, nowMs);
        rowStmt.bind(2, nowMs);
        rowStmt.bind(3, id);
        rowStmt.step();

        // INSERT...SELECT with WHERE id=? against a missing source inserts zero
        // rows but doesn't throw — and lastInsertRowId() retains its previous
        // value, so we MUST gate on changes() to know whether anything happened.
        // Without commit, the Transaction destructor rolls back.
        if (m_impl->conn.changes() == 0) return 0;
        const qint64 newId = m_impl->conn.lastInsertRowId();

        auto& secStmt = m_impl->duplicateSongSections;
        secStmt.reset();
        secStmt.bind(1, newId);
        secStmt.bind(2, id);
        secStmt.step();

        auto& fts = m_impl->upsertFtsForSong;
        fts.reset();
        fts.bind(1, newId);
        fts.step();

        tx.commit();
        invalidateCache();
        return newId;
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::duplicate():" << e.message();
        return 0;
    }
}

QFuture<void> SongService::rebuildFtsIndex()
{
    return QtConcurrent::run([]() {
        try {
            db::Connection conn(db::DbPaths::songsDbPath());
            db::Transaction tx(conn);
            conn.exec(QStringLiteral("DELETE FROM songs_fts"));
            conn.exec(QStringLiteral(
                "INSERT INTO songs_fts (rowid, title, author, lyrics) "
                "SELECT s.id, s.title, COALESCE(s.author, ''), "
                "       COALESCE((SELECT GROUP_CONCAT(lines_json, ' ') "
                "                 FROM song_sections WHERE song_id = s.id), '') "
                "FROM songs s"));
            tx.commit();
            qInfo() << "SongService: FTS index rebuilt";
        } catch (const db::Error& e) {
            qCritical().noquote() << "SongService::rebuildFtsIndex():" << e.message();
        }
    });
}

}  // namespace crater
