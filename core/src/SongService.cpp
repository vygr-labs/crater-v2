#include "crater/SongService.h"

#include "crater/LyricsDSL.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/FtsQuery.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSet>
#include <QtConcurrent>

#include <algorithm>
#include <optional>
#include <vector>

namespace {

// The schema's CHECK constraint accepts only these kinds; everything else
// has to be remapped or the INSERT throws SQLITE_CONSTRAINT. The editor lets
// the operator type a free-form label like "Bridge 2", but `kind` is structural
// — it drives projection-side styling rules later — so we keep it constrained.
const QSet<QString>& validSectionKinds()
{
    static const QSet<QString> s {
        QStringLiteral("verse"),     QStringLiteral("chorus"),
        QStringLiteral("bridge"),    QStringLiteral("intro"),
        QStringLiteral("outro"),     QStringLiteral("tag"),
        QStringLiteral("prechorus"), QStringLiteral("interlude"),
        QStringLiteral("other"),
    };
    return s;
}

// Best-effort guess at section kind from a free-form label. Editor users
// rarely set kind explicitly; mapping by common labels keeps stored kind
// usable for downstream styling without making them think about taxonomy.
QString inferKindFromLabel(const QString& label)
{
    const QString l = label.trimmed().toLower();
    if (l.startsWith(QStringLiteral("verse")))     return QStringLiteral("verse");
    if (l.startsWith(QStringLiteral("chorus")))    return QStringLiteral("chorus");
    if (l.startsWith(QStringLiteral("bridge")))    return QStringLiteral("bridge");
    if (l.startsWith(QStringLiteral("intro")))     return QStringLiteral("intro");
    if (l.startsWith(QStringLiteral("outro")))     return QStringLiteral("outro");
    if (l.startsWith(QStringLiteral("tag")))       return QStringLiteral("tag");
    if (l.startsWith(QStringLiteral("pre")))       return QStringLiteral("prechorus");
    if (l.startsWith(QStringLiteral("interlude"))) return QStringLiteral("interlude");
    return QStringLiteral("other");
}

QString sanitizeKind(const QString& rawKind, const QString& label)
{
    const QString k = rawKind.trimmed().toLower();
    if (validSectionKinds().contains(k)) return k;
    return inferKindFromLabel(label);
}

QByteArray linesToJson(const QStringList& lines)
{
    QJsonArray arr;
    for (const auto& line : lines) arr.append(line);
    return QJsonDocument(arr).toJson(QJsonDocument::Compact);
}

// Build a single space-separated plain-text string from a list of DSL lines,
// stripping all markdown-like markers (** _ ++ {color=…}). Used to feed the
// FTS5 index: bm25 ranking is cleaner when the token stream is just words,
// not the `*`/`+`/`{`/`}` chars from the DSL grammar. Newlines collapse to
// single spaces because FTS5 doesn't treat them specially anyway.
QString flattenDslLines(const QStringList& dslLines)
{
    QString out;
    bool first = true;
    for (const QString& line : dslLines) {
        const QString plain = crater::lyrics::flattenLine(line);
        if (plain.isEmpty()) continue;
        if (!first) out.append(QLatin1Char(' '));
        first = false;
        out.append(plain);
    }
    return out;
}

// Decode lines_json from a song_sections row and pass through flattenDslLines.
// Used by FTS code paths that need to materialize the OLD or CURRENT lyrics
// for an existing song (e.g. delete-and-reinsert during update, full rebuild).
QString flattenLinesFromJson(const QString& linesJsonText)
{
    const QJsonDocument doc = QJsonDocument::fromJson(linesJsonText.toUtf8());
    if (!doc.isArray()) return QString();
    QStringList lines;
    for (const auto& v : doc.array()) lines.append(v.toString());
    return flattenDslLines(lines);
}

// Project a section-shaped QVariantMap list (the QML side hands these in
// for create/update calls) down to a single FTS-ready plain string. Lives
// here so create/createWithSections/update share one code path for FTS
// content derivation.
QString flattenSectionsForFts(const QVariantList& sections)
{
    QString out;
    bool first = true;
    for (const QVariant& v : sections) {
        const QVariantMap m = v.toMap();
        const QStringList lines = m.value(QStringLiteral("lines")).toStringList();
        for (const QString& line : lines) {
            const QString plain = crater::lyrics::flattenLine(line);
            if (plain.isEmpty()) continue;
            if (!first) out.append(QLatin1Char(' '));
            first = false;
            out.append(plain);
        }
    }
    return out;
}

// Build a short lyric excerpt centered on the first place any search term
// occurs in the (already flattened, plain-text) lyrics. Case-insensitive.
// The window is snapped out to whole words and bracketed with ellipses when
// it doesn't reach the start/end of the lyrics. Returns empty when no term is
// present (e.g. the FTS hit was on title/author, not lyrics).
QString makeSnippet(const QString& lyrics, const QStringList& terms, int radius = 44)
{
    if (lyrics.isEmpty() || terms.isEmpty()) return QString();

    const QString hay = lyrics.toLower();
    int matchPos = -1;
    int matchLen = 0;
    for (const QString& term : terms) {
        const int pos = hay.indexOf(term);
        if (pos >= 0 && (matchPos < 0 || pos < matchPos)) {
            matchPos = pos;
            matchLen = term.size();
        }
    }
    if (matchPos < 0) return QString();

    int start = qMax(0, matchPos - radius);
    int end   = qMin(lyrics.size(), matchPos + matchLen + radius);
    // Snap to word boundaries so the excerpt never begins/ends mid-word.
    while (start > 0 && !lyrics.at(start - 1).isSpace()) --start;
    while (end < lyrics.size() && !lyrics.at(end).isSpace()) ++end;

    QString snip = lyrics.mid(start, end - start).trimmed();
    if (start > 0)             snip.prepend(QStringLiteral("… "));
    if (end < lyrics.size())   snip.append(QStringLiteral(" …"));
    return snip;
}

// ── Typo-tolerant fuzzy fallback ────────────────────────────────────────────
// Used only when exact FTS returns nothing: fuzzy-match the query words
// against a song's title/author word tokens so a misspelled title still
// surfaces. All strings here are short (query words, title/author tokens), so
// the bounded edit-distance stays cheap even across a few thousand songs.

// Bounded Levenshtein: returns the edit distance, or maxDist+1 as soon as it's
// provably greater (row-minimum prune + length prune), so no full DP is paid
// for obviously-distant pairs.
int boundedLevenshtein(const QString& a, const QString& b, int maxDist)
{
    const int la = a.size(), lb = b.size();
    if (qAbs(la - lb) > maxDist) return maxDist + 1;
    if (la == 0) return lb <= maxDist ? lb : maxDist + 1;
    if (lb == 0) return la <= maxDist ? la : maxDist + 1;

    std::vector<int> prev(lb + 1), curr(lb + 1);
    for (int j = 0; j <= lb; ++j) prev[j] = j;
    for (int i = 1; i <= la; ++i) {
        curr[0] = i;
        int rowMin = curr[0];
        const QChar ca = a.at(i - 1);
        for (int j = 1; j <= lb; ++j) {
            const int cost = (ca == b.at(j - 1)) ? 0 : 1;
            curr[j] = std::min({ prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost });
            if (curr[j] < rowMin) rowMin = curr[j];
        }
        if (rowMin > maxDist) return maxDist + 1;
        std::swap(prev, curr);
    }
    return prev[lb] <= maxDist ? prev[lb] : maxDist + 1;
}

// Split into lowercased alphanumeric word tokens (punctuation/space delimit).
QStringList wordTokens(const QString& s)
{
    QStringList out;
    QString cur;
    for (const QChar& c : s) {
        if (c.isLetterOrNumber()) {
            cur.append(c.toLower());
        } else if (!cur.isEmpty()) {
            out.append(cur);
            cur.clear();
        }
    }
    if (!cur.isEmpty()) out.append(cur);
    return out;
}

// Max edit distance tolerated for a query word of the given length. Short
// words get 0 (a 1-char slip on a 3-letter word matches half the dictionary);
// longer words scale up.
int termThreshold(int len)
{
    if (len <= 3)  return 0;
    if (len <= 5)  return 1;
    if (len <= 8)  return 2;
    return 3;
}

// Score a candidate: every query term must fuzzily match some token, else the
// candidate is rejected (returns -1). Otherwise returns the summed distance —
// lower is a closer match.
int fuzzyScore(const QStringList& qterms, const QStringList& tokens)
{
    int total = 0;
    for (const QString& q : qterms) {
        const int thr = termThreshold(q.size());
        int best = thr + 1;
        for (const QString& t : tokens) {
            const int d = boundedLevenshtein(q, t, thr);
            if (d < best) best = d;
            if (best == 0) break;
        }
        if (best > thr) return -1;
        total += best;
    }
    return total;
}

}  // namespace

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
    db::Statement updateSong;
    db::Statement deleteSong;
    db::Statement toggleFavorite;
    db::Statement upsertFtsForSong;
    db::Statement deleteFtsForSong;
    // Two-step deep copy. INSERT...SELECT keeps the data inside SQLite so no
    // QString round-trip is needed for the sections (lines_json can be large).
    db::Statement duplicateSongRow;
    db::Statement duplicateSongSections;
    // Per-section helpers used by createWithSections() and update().
    db::Statement insertSection;
    db::Statement deleteSectionsForSong;
    // Lightweight existence check used by update() to refuse silently rather
    // than INSERT-or-UPDATE-by-default. Keeps "song was deleted in another
    // window since I opened the editor" from creating a phantom new song.
    db::Statement existsSong;

    // Cached allSongs() result. Invalidated on any mutation.
    std::optional<QList<Song>> cachedAll;

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("SongService"))
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
            // Weighted bm25: songs_fts columns are (title, author, lyrics) in
            // that order, so the weights bias a title hit far above a stray
            // lyric word and an author hit in between. Without weights a match
            // buried in verse 3 ranked equal to the song's own title.
            "SELECT DISTINCT s.id, s.title, s.author, s.copyright, s.ccli, "
            "       s.theme_id, s.is_favorite, s.created_at, s.updated_at, "
            "       bm25(songs_fts, 10.0, 6.0, 1.0) AS score "
            "FROM songs_fts "
            "JOIN songs s ON s.id = songs_fts.rowid "
            "WHERE songs_fts MATCH ? "
            "ORDER BY score ASC LIMIT 100")))
        , insertSong(conn.prepare(QStringLiteral(
            "INSERT INTO songs (title, author, ccli, theme_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?)")))
        , updateSong(conn.prepare(QStringLiteral(
            // Binds: 1=title, 2=author, 3=ccli, 4=theme_id, 5=updated_at, 6=id
            "UPDATE songs SET title = ?, author = ?, ccli = ?, "
            "       theme_id = ?, updated_at = ? WHERE id = ?")))
        , deleteSong(conn.prepare(QStringLiteral(
            "DELETE FROM songs WHERE id = ?")))
        , toggleFavorite(conn.prepare(QStringLiteral(
            "UPDATE songs SET is_favorite = NOT is_favorite, updated_at = ? WHERE id = ?")))
        , upsertFtsForSong(conn.prepare(QStringLiteral(
            // Lyrics arrive pre-flattened from C++ (DSL markers stripped)
            // because the FTS5 trigram tokenizer would otherwise index `*`,
            // `+`, `{`, `}` as ordinary chars and degrade bm25 ranking. Title
            // and author are SELECTed inline — they're plain text already.
            // Binds: 1 = flattened lyrics, 2 = song id.
            "INSERT INTO songs_fts (rowid, title, author, lyrics) "
            "SELECT s.id, s.title, COALESCE(s.author, ''), ? "
            "FROM songs s WHERE s.id = ?")))
        , deleteFtsForSong(conn.prepare(QStringLiteral(
            // songs_fts is a CONTENTLESS FTS5 table (content=''), so a plain
            // DELETE is rejected by SQLite with "cannot DELETE from contentless
            // fts5 table". The only way to remove a row is the FTS5 'delete'
            // command, which requires the OLD column values so FTS can subtract
            // the right tokens from the inverted index.
            //
            // The lyrics value MUST be the same FLATTENED form that was
            // INSERTed by upsertFtsForSong — otherwise the index becomes
            // inconsistent (Phase 6: we strip DSL markers everywhere FTS
            // touches lyrics). Callers compute the flatten in C++ via
            // flattenLinesFromJson() over the CURRENT song_sections rows
            // (before any mutation) and bind it as parameter 1.
            "INSERT INTO songs_fts(songs_fts, rowid, title, author, lyrics) "
            "SELECT 'delete', s.id, s.title, COALESCE(s.author, ''), ? "
            "FROM songs s WHERE s.id = ?")))
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
        , insertSection(conn.prepare(QStringLiteral(
            // Binds (1=song_id, 2=label, 3=kind, 4=lines_json, 5=sort_order).
            "INSERT INTO song_sections (song_id, label, kind, lines_json, sort_order) "
            "VALUES (?, ?, ?, ?, ?)")))
        , deleteSectionsForSong(conn.prepare(QStringLiteral(
            "DELETE FROM song_sections WHERE song_id = ?")))
        , existsSong(conn.prepare(QStringLiteral(
            "SELECT 1 FROM songs WHERE id = ?")))
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

    // Pull the CURRENT (pre-mutation) flattened lyrics for a song from the
    // song_sections table — DSL markers stripped, lines space-joined. Used
    // by deleteFtsForSong / pre-update workflows so the FTS5 'delete'
    // command receives values matching what was originally inserted.
    QString fetchFlattenedLyrics(qint64 songId)
    {
        auto& stmt = selectSectionsForSong;
        stmt.reset();
        stmt.bind(1, songId);
        QString out;
        bool first = true;
        while (stmt.step()) {
            const QString linesJsonText = stmt.columnText(2);
            const QJsonDocument doc = QJsonDocument::fromJson(linesJsonText.toUtf8());
            if (!doc.isArray()) continue;
            for (const auto& v : doc.array()) {
                const QString plain = crater::lyrics::flattenLine(v.toString());
                if (plain.isEmpty()) continue;
                if (!first) out.append(QLatin1Char(' '));
                first = false;
                out.append(plain);
            }
        }
        return out;
    }
};

SongService::SongService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::songsDbPath());

        // Phase 6 auto-heal: V002 migration clears songs_fts so that the
        // index can be repopulated with FLATTENED lyrics (DSL markers
        // stripped). If we detect that condition — non-empty songs table
        // alongside an empty songs_fts — fire a sync rebuild now so the
        // first search after startup returns hits. Subsequent launches
        // hit this path with `ftsCount == songCount`, short-circuit, and
        // pay only two trivial COUNT queries.
        auto songCountStmt = m_impl->conn.prepare(
            QStringLiteral("SELECT count(*) FROM songs"));
        int songCount = 0;
        if (songCountStmt.step()) songCount = songCountStmt.columnInt(0);
        songCountStmt.reset();   // close cursor before the rebuild write below

        if (songCount > 0) {
            auto ftsCountStmt = m_impl->conn.prepare(
                QStringLiteral("SELECT count(*) FROM songs_fts"));
            int ftsCount = 0;
            if (ftsCountStmt.step()) ftsCount = ftsCountStmt.columnInt(0);
            ftsCountStmt.reset();   // close cursor before rebuildFtsIndex()
            if (ftsCount == 0) {
                qInfo().noquote() << "SongService: songs_fts empty for"
                                  << songCount << "songs — rebuilding now";
                // Use the QFuture path for code-sharing; wait on it
                // synchronously so the service is search-ready by the
                // time QML binds against it.
                rebuildFtsIndex().waitForFinished();
            }
        }
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

void SongService::reload()
{
    // The EasyWorship importer writes songs.sqlite on a worker thread,
    // outside this service. Invalidating the cache here makes the next
    // allSongs() re-query the DB so the imported rows become visible.
    invalidateCache();
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
        // Close the cursor now that the row is copied out. A SELECT left in
        // the SQLITE_ROW state keeps an implicit read transaction open on this
        // connection — and under WAL that pins a database snapshot, so every
        // later query here (allSongs(), search()) would keep reading a stale
        // view. Concretely: rows the EasyWorship importer commits on its own
        // connection would stay invisible until the app restarts. reset()
        // ends the read transaction; the next query opens a fresh snapshot.
        meta.reset();

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
    if (!m_impl) return out;

    // Sanitize the raw query into a safe FTS5 MATCH expression (quote every
    // term, drop sub-3-char words the trigram tokenizer can't match, honor
    // "phrases"/OR/-exclude). Empty → nothing searchable; skip FTS entirely.
    const db::FtsQuery fts = db::buildFtsQuery(query);
    if (fts.isEmpty()) return out;

    try {
        auto& stmt = m_impl->searchFts;
        stmt.reset();
        stmt.bind(1, fts.match);
        while (stmt.step()) {
            out.append(m_impl->readSongRow(stmt));
        }
    } catch (const db::Error& e) {
        // Should be rare now that input is sanitized; log quietly and bail.
        qDebug().noquote() << "SongService::search():" << e.message();
        return out;
    }

    // Second pass — attach a matched-lyric snippet to each hit. Run only after
    // the search cursor drains to SQLITE_DONE (self-releasing its read txn) so
    // we never interleave two open cursors on the one connection.
    for (Song& song : out) {
        const QString lyrics = m_impl->fetchFlattenedLyrics(song.id);
        song.snippet = makeSnippet(lyrics, fts.terms);
    }

    // Typo-tolerant fallback: exact FTS found nothing, so fuzzy-match the query
    // words against song title + author tokens (metadata only — cheap, and the
    // title is what operators misspell). allSongs() is cached; this pass only
    // runs on the otherwise-empty path.
    if (out.isEmpty()) {
        QStringList qterms;
        for (const QString& w : wordTokens(query)) {
            if (w.size() >= 3) qterms.append(w);
        }
        if (!qterms.isEmpty()) {
            struct Scored { int score; Song song; };
            std::vector<Scored> scored;
            const QList<Song> all = allSongs();
            for (const Song& s : all) {
                QStringList tokens = wordTokens(s.title);
                tokens += wordTokens(s.author);
                const int sc = fuzzyScore(qterms, tokens);
                if (sc >= 0) scored.push_back({ sc, s });
            }
            std::stable_sort(scored.begin(), scored.end(),
                             [](const Scored& a, const Scored& b) { return a.score < b.score; });
            constexpr int kFuzzyCap = 25;
            const int n = std::min<int>(static_cast<int>(scored.size()), kFuzzyCap);
            for (int i = 0; i < n; ++i) {
                Song s = scored[i].song;
                s.fuzzy = true;
                out.append(std::move(s));
            }
        }
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
        stmt.bindNull(4);         // theme_id — "use default for kind"
        stmt.bind(5, nowMs);
        stmt.bind(6, nowMs);
        stmt.step();

        const qint64 id = m_impl->conn.lastInsertRowId();

        // Sync FTS row for the new song. No sections yet, so lyrics = "".
        auto& fts = m_impl->upsertFtsForSong;
        fts.reset();
        fts.bind(1, QString());
        fts.bind(2, id);
        fts.step();

        invalidateCache();
        return id;
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::create():" << e.message();
        return 0;
    }
}

qint64 SongService::createWithSections(QString title, QString author, QString ccli,
                                       qint64 themeId, QVariantList sections)
{
    if (!m_impl) return 0;
    try {
        db::Transaction tx(m_impl->conn);
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();

        auto& songStmt = m_impl->insertSong;
        songStmt.reset();
        songStmt.bind(1, title);
        songStmt.bind(2, author);
        if (ccli.isEmpty()) songStmt.bindNull(3); else songStmt.bind(3, ccli);
        if (themeId <= 0)   songStmt.bindNull(4); else songStmt.bind(4, themeId);
        songStmt.bind(5, nowMs);
        songStmt.bind(6, nowMs);
        songStmt.step();

        const qint64 newId = m_impl->conn.lastInsertRowId();

        // Section insert loop. sort_order is the loop index so the editor's
        // section order survives the round-trip (selectSectionsForSong ORDERs
        // by sort_order). Empty section lists are valid — the song still
        // exists as a metadata row, projection just shows nothing yet.
        auto& secStmt = m_impl->insertSection;
        for (int i = 0; i < sections.size(); ++i) {
            const QVariantMap m = sections.at(i).toMap();
            const QString label = m.value(QStringLiteral("label")).toString();
            const QString kind  = sanitizeKind(m.value(QStringLiteral("kind")).toString(), label);
            const QStringList lines = m.value(QStringLiteral("lines")).toStringList();

            secStmt.reset();
            secStmt.bind(1, newId);
            secStmt.bind(2, label);
            secStmt.bind(3, kind);
            secStmt.bind(4, QString::fromUtf8(linesToJson(lines)));
            secStmt.bind(5, i);
            secStmt.step();
        }

        // FTS sync runs after sections so the new song's row exists when
        // we INSERT. Lyrics are flattened from the input QVariantList — no
        // need to re-fetch from DB since we already have the canonical
        // section list in hand.
        auto& fts = m_impl->upsertFtsForSong;
        fts.reset();
        fts.bind(1, flattenSectionsForFts(sections));
        fts.bind(2, newId);
        fts.step();

        tx.commit();
        invalidateCache();
        return newId;
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::createWithSections():" << e.message();
        return 0;
    }
}

bool SongService::update(qint64 id, QString title, QString author, QString ccli,
                         qint64 themeId, QVariantList sections)
{
    if (!m_impl || id <= 0) return false;
    try {
        // Refuse to write to a song that no longer exists. Without this an
        // UPDATE silently affects 0 rows and the FTS / cache invalidations
        // below run anyway, masking the "you're editing a deleted song" case.
        auto& existsStmt = m_impl->existsSong;
        existsStmt.reset();
        existsStmt.bind(1, id);
        if (!existsStmt.step()) {
            qWarning().noquote() << "SongService::update(): song" << id << "does not exist";
            return false;
        }
        // Probe done — close its cursor so it doesn't leave a read
        // transaction dangling on the connection (same WAL snapshot-pinning
        // hazard documented in fetchSong()).
        existsStmt.reset();

        db::Transaction tx(m_impl->conn);
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();

        // FTS bookkeeping must straddle the source-table mutation:
        //   1. Fetch OLD flattened lyrics from the CURRENT song_sections
        //      rows BEFORE any mutation. These match what's currently
        //      indexed in songs_fts (Phase 6: FTS stores flattened DSL).
        //   2. Issue the FTS 'delete' command with the OLD lyrics so the
        //      index removes exactly the tokens that were previously
        //      inserted — required for index consistency.
        //   3. Mutate songs + song_sections (UPDATE songs, DELETE + INSERT
        //      song_sections to replace them wholesale).
        //   4. upsertFtsForSong with the NEW flattened lyrics computed
        //      directly from the input QVariantList.
        const QString oldLyrics = m_impl->fetchFlattenedLyrics(id);
        auto& delFts = m_impl->deleteFtsForSong;
        delFts.reset();
        delFts.bind(1, oldLyrics);
        delFts.bind(2, id);
        delFts.step();

        auto& upd = m_impl->updateSong;
        upd.reset();
        upd.bind(1, title);
        upd.bind(2, author);
        if (ccli.isEmpty())   upd.bindNull(3); else upd.bind(3, ccli);
        if (themeId <= 0)     upd.bindNull(4); else upd.bind(4, themeId);
        upd.bind(5, nowMs);
        upd.bind(6, id);
        upd.step();

        // Replace sections wholesale. Cheaper + simpler than diffing the small
        // section list — 5-10 rows typical, never more than ~30 even for hymns
        // with extensive choruses. ON DELETE CASCADE on the songs FK doesn't
        // help here; we're deleting only the sections, not the song.
        auto& delSecs = m_impl->deleteSectionsForSong;
        delSecs.reset();
        delSecs.bind(1, id);
        delSecs.step();

        auto& secStmt = m_impl->insertSection;
        for (int i = 0; i < sections.size(); ++i) {
            const QVariantMap m = sections.at(i).toMap();
            const QString label = m.value(QStringLiteral("label")).toString();
            const QString kind  = sanitizeKind(m.value(QStringLiteral("kind")).toString(), label);
            const QStringList lines = m.value(QStringLiteral("lines")).toStringList();

            secStmt.reset();
            secStmt.bind(1, id);
            secStmt.bind(2, label);
            secStmt.bind(3, kind);
            secStmt.bind(4, QString::fromUtf8(linesToJson(lines)));
            secStmt.bind(5, i);
            secStmt.step();
        }

        // FTS row was already deleted at the top of the transaction (using
        // the OLD flattened lyrics). Now insert with the NEW flattened
        // lyrics computed from the input sections.
        auto& fts = m_impl->upsertFtsForSong;
        fts.reset();
        fts.bind(1, flattenSectionsForFts(sections));
        fts.bind(2, id);
        fts.step();

        tx.commit();
        invalidateCache();
        return true;
    } catch (const db::Error& e) {
        qWarning().noquote() << "SongService::update():" << e.message();
        return false;
    }
}

void SongService::destroy(qint64 id)
{
    if (!m_impl) return;
    try {
        db::Transaction tx(m_impl->conn);
        // Same ordering rule as update(): compute OLD flattened lyrics
        // before any mutation so the FTS 'delete' command receives values
        // matching what was originally INSERTed.
        const QString oldLyrics = m_impl->fetchFlattenedLyrics(id);
        auto& delFts = m_impl->deleteFtsForSong;
        delFts.reset();
        delFts.bind(1, oldLyrics);
        delFts.bind(2, id);
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

        // For a duplicate, the new song's lyrics ARE the original's. Read
        // them back from the freshly-inserted song_sections rows and
        // flatten — that's cheaper than carrying the data through a
        // QVariantList path that doesn't exist here, and it matches what
        // a subsequent update/destroy will read for OLD-lyric purposes.
        auto& fts = m_impl->upsertFtsForSong;
        fts.reset();
        fts.bind(1, m_impl->fetchFlattenedLyrics(newId));
        fts.bind(2, newId);
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
            // Worker thread gets its own connection — never share a
            // db::Connection or its prepared statements across threads.
            db::Connection conn(db::DbPaths::songsDbPath());
            db::Transaction tx(conn);

            // 'delete-all' is the only way to clear a contentless FTS5
            // table — plain `DELETE FROM songs_fts` is rejected. This
            // wipes the inverted index without needing per-row values.
            conn.exec(QStringLiteral(
                "INSERT INTO songs_fts(songs_fts) VALUES('delete-all')"));

            // Walk songs + their sections in C++ so we can run flattenLine
            // on each DSL line. SQL can't do that — the DSL parser lives
            // in crater::lyrics. Two prepared statements, one inserted
            // row per song.
            db::Statement songsStmt = conn.prepare(QStringLiteral(
                "SELECT id FROM songs"));
            db::Statement sectionsStmt = conn.prepare(QStringLiteral(
                "SELECT lines_json FROM song_sections WHERE song_id = ? "
                "ORDER BY sort_order"));
            db::Statement insertFts = conn.prepare(QStringLiteral(
                "INSERT INTO songs_fts (rowid, title, author, lyrics) "
                "SELECT s.id, s.title, COALESCE(s.author, ''), ? "
                "FROM songs s WHERE s.id = ?"));

            int nSongs = 0;
            while (songsStmt.step()) {
                const qint64 sid = songsStmt.columnInt64(0);

                // Flatten this song's lyrics by walking each section's
                // lines_json and stripping DSL markers.
                QString lyrics;
                bool first = true;
                sectionsStmt.reset();
                sectionsStmt.bind(1, sid);
                while (sectionsStmt.step()) {
                    const QString linesJsonText = sectionsStmt.columnText(0);
                    const QJsonDocument doc =
                        QJsonDocument::fromJson(linesJsonText.toUtf8());
                    if (!doc.isArray()) continue;
                    for (const auto& v : doc.array()) {
                        const QString plain = crater::lyrics::flattenLine(v.toString());
                        if (plain.isEmpty()) continue;
                        if (!first) lyrics.append(QLatin1Char(' '));
                        first = false;
                        lyrics.append(plain);
                    }
                }

                insertFts.reset();
                insertFts.bind(1, lyrics);
                insertFts.bind(2, sid);
                insertFts.step();
                ++nSongs;
            }

            tx.commit();
            qInfo().noquote() << "SongService: FTS index rebuilt for"
                              << nSongs << "songs";
        } catch (const db::Error& e) {
            qCritical().noquote() << "SongService::rebuildFtsIndex():" << e.message();
        }
    });
}

}  // namespace crater
