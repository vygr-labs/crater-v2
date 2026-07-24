#include "crater/EasyWorshipImporter.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"
#include "import/Rtf.h"

#include <QDateTime>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QList>
#include <QRegularExpression>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QtConcurrent>

#include <optional>

namespace crater {

namespace {

// ── EasyWorship database identification ──────────────────────────────────────

struct EwPair
{
    QString songsPath;   // the file holding the `song` table
    QString wordsPath;   // the file holding the `word` table
};

bool tableExists(db::Connection& c, const QString& name)
{
    auto stmt = c.prepare(QStringLiteral(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"));
    stmt.bind(1, name);
    return stmt.step();
}

// Lower-cased column names of the EasyWorship `song` table. EasyWorship's
// schema varies a little across versions, so callers probe rather than assume.
QSet<QString> ewSongColumns(db::Connection& c)
{
    QSet<QString> cols;
    auto stmt = c.prepare(QStringLiteral("PRAGMA table_info(song)"));
    while (stmt.step()) cols.insert(stmt.columnText(1).toLower());
    return cols;
}

// Identify which selected file is Songs.db and which is SongWords.db by
// looking at the tables each one contains — filenames and selection order
// are not trusted. Returns nullopt and sets `err` on any problem.
std::optional<EwPair> identifyFiles(const QStringList& files, QString& err)
{
    if (files.size() != 2) {
        err = QStringLiteral("Select exactly two files — your EasyWorship "
                             "Songs.db and SongWords.db.");
        return std::nullopt;
    }

    EwPair pair;
    for (const QString& f : files) {
        try {
            db::Connection c(f, db::OpenMode::ReadOnly);
            if (tableExists(c, QStringLiteral("song")))
                pair.songsPath = f;
            else if (tableExists(c, QStringLiteral("word")))
                pair.wordsPath = f;
        } catch (const db::Error&) {
            err = QStringLiteral("Not a readable database file: %1")
                      .arg(QFileInfo(f).fileName());
            return std::nullopt;
        }
    }

    if (pair.songsPath.isEmpty() || pair.wordsPath.isEmpty()) {
        err = QStringLiteral("Could not find an EasyWorship Songs.db and "
                             "SongWords.db among the selected files.");
        return std::nullopt;
    }
    return pair;
}

// ── Duplicate detection ──────────────────────────────────────────────────────

// Collapse a (title, author) pair to a single case- and whitespace-normalized
// key. The 0x1F unit separator can't occur in a title or author, so it joins
// the two fields without risk of a "Foo" + "Bar" / "Foo Bar" collision.
QString dupKey(const QString& title, const QString& author)
{
    return title.simplified().toLower()
         + QLatin1Char('\x1f')
         + author.simplified().toLower();
}

QSet<QString> loadExistingKeys(db::Connection& songsDb)
{
    QSet<QString> keys;
    auto stmt = songsDb.prepare(QStringLiteral(
        "SELECT title, COALESCE(author, '') FROM songs"));
    while (stmt.step())
        keys.insert(dupKey(stmt.columnText(0), stmt.columnText(1)));
    return keys;
}

// ── Lyric sectioning ─────────────────────────────────────────────────────────

struct ParsedSection
{
    QString     label;   // "" when the block had no recognizable heading
    QStringList lines;   // plain-text lyric lines (no DSL escaping yet)
};

// A line is a section heading only if the WHOLE line is a known section word
// plus an optional number — "Verse 1", "Chorus", "Bridge 2". This deliberately
// rejects lyric lines that merely start with such a word ("Bridge over...").
bool isSectionHeader(const QString& line)
{
    static const QRegularExpression re(
        QStringLiteral("^(verse|chorus|pre[ -]?chorus|bridge|tag|intro|outro|"
                       "ending|end|interlude|refrain)\\s*\\d*$"),
        QRegularExpression::CaseInsensitiveOption);
    return re.match(line).hasMatch();
}

// Map a heading to a song_sections.kind value. The schema CHECK constraint
// accepts only a fixed set, so anything unrecognized falls back to "other".
QString labelToKind(const QString& label)
{
    const QString l = label.trimmed().toLower();
    if (l.startsWith(QStringLiteral("verse")))     return QStringLiteral("verse");
    if (l.startsWith(QStringLiteral("pre")))       return QStringLiteral("prechorus");
    if (l.startsWith(QStringLiteral("chorus")))    return QStringLiteral("chorus");
    if (l.startsWith(QStringLiteral("refrain")))   return QStringLiteral("chorus");
    if (l.startsWith(QStringLiteral("bridge")))    return QStringLiteral("bridge");
    if (l.startsWith(QStringLiteral("intro")))     return QStringLiteral("intro");
    if (l.startsWith(QStringLiteral("outro")))     return QStringLiteral("outro");
    if (l.startsWith(QStringLiteral("end")))       return QStringLiteral("outro");
    if (l.startsWith(QStringLiteral("tag")))       return QStringLiteral("tag");
    if (l.startsWith(QStringLiteral("interlude"))) return QStringLiteral("interlude");
    return QStringLiteral("other");
}

// Split RTF-extracted plain text into sections. A blank line ends the current
// section; a heading line starts a new one (and becomes its label). Text that
// appears before any heading forms a leading section with an empty label.
QList<ParsedSection> splitSections(const QString& plainText)
{
    QList<ParsedSection> result;
    ParsedSection current;
    bool hasContent = false;

    const auto flush = [&]() {
        if (hasContent || !current.label.isEmpty())
            result.append(current);
        current = ParsedSection{};
        hasContent = false;
    };

    const QStringList rawLines = plainText.split(QLatin1Char('\n'));
    for (const QString& rawLine : rawLines) {
        const QString line = rawLine.trimmed();
        if (line.isEmpty()) {
            if (hasContent) flush();   // a blank line only ends a section with body lines
            continue;
        }
        if (isSectionHeader(line)) {
            flush();
            current.label = line;
        } else {
            current.lines.append(line);
            hasContent = true;
        }
    }
    flush();
    return result;
}

// ── DSL / JSON encoding ──────────────────────────────────────────────────────

// Escape the three characters the lyric DSL treats as markup so an imported
// plain-text line round-trips through crater::lyrics unchanged.
QString escapeDsl(const QString& plain)
{
    QString out;
    out.reserve(plain.size());
    for (const QChar ch : plain) {
        if (ch == QLatin1Char('\\') || ch == QLatin1Char('*') || ch == QLatin1Char('{'))
            out.append(QLatin1Char('\\'));
        out.append(ch);
    }
    return out;
}

QString linesToJson(const QStringList& lines)
{
    QJsonArray arr;
    for (const QString& l : lines) arr.append(l);
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────

EasyWorshipImporter::EasyWorshipImporter(QObject* parent)
    : QObject(parent)
{}

EasyWorshipImporter::~EasyWorshipImporter()
{
    // Block until any in-flight worker finishes, so its queued signal
    // emissions and `this` capture stay valid through teardown — e.g. when
    // the operator quits the app while an import is still running.
    if (m_task.isValid()) m_task.waitForFinished();
}

void EasyWorshipImporter::analyze(QStringList dbFiles)
{
    m_task = QtConcurrent::run([this, dbFiles]() {
        try {
            QString err;
            const auto pair = identifyFiles(dbFiles, err);
            if (!pair) {
                emit failed(err);
                return;
            }

            db::Connection songsDb(pair->songsPath, db::OpenMode::ReadOnly);
            const QSet<QString> cols = ewSongColumns(songsDb);
            if (!cols.contains(QStringLiteral("title"))) {
                emit failed(QStringLiteral("This does not look like an "
                                           "EasyWorship song database."));
                return;
            }
            const bool hasAuthor = cols.contains(QStringLiteral("author"));

            db::Connection lib(db::DbPaths::songsDbPath(), db::OpenMode::ReadOnly);
            const QSet<QString> existing = loadExistingKeys(lib);

            auto sel = songsDb.prepare(hasAuthor
                ? QStringLiteral("SELECT title, COALESCE(author, '') FROM song")
                : QStringLiteral("SELECT title, '' FROM song"));

            int total      = 0;
            int duplicates = 0;
            while (sel.step()) {
                const QString title = sel.columnText(0).simplified();
                if (title.isEmpty()) continue;
                const QString author = sel.columnText(1).simplified();
                ++total;
                if (existing.contains(dupKey(title, author))) ++duplicates;
            }
            emit analyzed(total, duplicates);
        } catch (const db::Error& e) {
            emit failed(e.message());
        } catch (...) {
            emit failed(QStringLiteral("Unexpected error while scanning the "
                                       "EasyWorship database."));
        }
    });
}

void EasyWorshipImporter::run(QStringList dbFiles, bool skipDuplicates)
{
    m_task = QtConcurrent::run([this, dbFiles, skipDuplicates]() {
        try {
            QString err;
            const auto pair = identifyFiles(dbFiles, err);
            if (!pair) {
                emit failed(err);
                return;
            }

            emit progress(0, QStringLiteral("Opening EasyWorship databases..."));

            db::Connection songsDb(pair->songsPath, db::OpenMode::ReadOnly);
            db::Connection wordsDb(pair->wordsPath, db::OpenMode::ReadOnly);

            const QSet<QString> cols = ewSongColumns(songsDb);
            if (!cols.contains(QStringLiteral("title"))) {
                emit failed(QStringLiteral("This does not look like an "
                                           "EasyWorship song database."));
                return;
            }
            const bool hasAuthor    = cols.contains(QStringLiteral("author"));
            const bool hasCopyright = cols.contains(QStringLiteral("copyright"));
            const bool hasCcli      = cols.contains(QStringLiteral("ccli_no"));

            // Absent columns become NULL placeholders so the column indices
            // read below stay fixed regardless of the EasyWorship version.
            QString songSql = QStringLiteral("SELECT rowid, title, ");
            songSql += hasAuthor    ? QStringLiteral("author")    : QStringLiteral("NULL");
            songSql += QStringLiteral(", ");
            songSql += hasCopyright ? QStringLiteral("copyright") : QStringLiteral("NULL");
            songSql += QStringLiteral(", ");
            songSql += hasCcli      ? QStringLiteral("ccli_no")   : QStringLiteral("NULL");
            songSql += QStringLiteral(" FROM song");

            int total = 0;
            {
                auto countStmt = songsDb.prepare(
                    QStringLiteral("SELECT COUNT(*) FROM song"));
                if (countStmt.step()) total = countStmt.columnInt(0);
            }

            db::Connection target(db::DbPaths::songsDbPath());
            const QSet<QString> existing =
                skipDuplicates ? loadExistingKeys(target) : QSet<QString>();

            // One transaction for the whole library — per-row commits would be
            // ~100x slower under WAL. A throw here rolls the whole import back.
            db::Transaction tx(target);

            auto songSel = songsDb.prepare(songSql);
            auto wordSel = wordsDb.prepare(
                QStringLiteral("SELECT words FROM word WHERE song_id = ?"));
            auto insSong = target.prepare(QStringLiteral(
                "INSERT INTO songs (title, author, copyright, ccli, theme_id, "
                "created_at, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?)"));
            auto insSection = target.prepare(QStringLiteral(
                "INSERT INTO song_sections (song_id, label, kind, lines_json, "
                "sort_order) VALUES (?, ?, ?, ?, ?)"));
            auto insFts = target.prepare(QStringLiteral(
                // Apostrophe-strip title/author/lyrics at index time (ASCII ' +
                // curly char(8217)) so EasyWorship-imported songs match the
                // apostrophe-normalised query and the identical normalisation
                // SongService's upsert / delete / rebuild apply. A mismatch
                // here would corrupt the contentless songs_fts index the first
                // time such a song is edited (the 'delete' would subtract
                // stripped tokens that were never inserted). rowid stays bare.
                "INSERT INTO songs_fts (rowid, title, author, lyrics) "
                "VALUES (?, "
                "        replace(replace(?, '''', ''), char(8217), ''), "
                "        replace(replace(?, '''', ''), char(8217), ''), "
                "        replace(replace(?, '''', ''), char(8217), ''))"));

            int processed = 0;
            int imported  = 0;
            int skipped   = 0;
            int lastPct   = -1;

            while (songSel.step()) {
                const qint64  ewId  = songSel.columnInt64(0);
                const QString title = songSel.columnText(1).simplified();
                const QString author = songSel.columnIsNull(2)
                    ? QString() : songSel.columnText(2).simplified();
                const QString copyright = songSel.columnIsNull(3)
                    ? QString() : songSel.columnText(3).trimmed();
                const QString ccli = songSel.columnIsNull(4)
                    ? QString() : songSel.columnText(4).trimmed();

                ++processed;

                if (!title.isEmpty()) {
                    if (skipDuplicates && existing.contains(dupKey(title, author))) {
                        ++skipped;
                    } else {
                        // Pull and decode the RTF lyric blob.
                        wordSel.reset();
                        wordSel.bind(1, ewId);
                        QString rtf;
                        if (wordSel.step()) rtf = wordSel.columnText(0);
                        const QString plain = crater::rtf::toPlainText(rtf);
                        const QList<ParsedSection> sections = splitSections(plain);

                        // Song metadata row.
                        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
                        insSong.reset();
                        insSong.bind(1, title);
                        if (author.isEmpty())    insSong.bindNull(2); else insSong.bind(2, author);
                        if (copyright.isEmpty()) insSong.bindNull(3); else insSong.bind(3, copyright);
                        if (ccli.isEmpty())      insSong.bindNull(4); else insSong.bind(4, ccli);
                        insSong.bind(5, nowMs);
                        insSong.bind(6, nowMs);
                        insSong.step();
                        const qint64 newId = target.lastInsertRowId();

                        // Section rows. lines_json stores DSL-escaped text;
                        // ftsLyrics collects the bare words for the index.
                        QString ftsLyrics;
                        for (int s = 0; s < sections.size(); ++s) {
                            const ParsedSection& sec = sections.at(s);
                            QStringList dslLines;
                            dslLines.reserve(sec.lines.size());
                            for (const QString& ln : sec.lines) {
                                dslLines.append(escapeDsl(ln));
                                if (!ftsLyrics.isEmpty()) ftsLyrics.append(QLatin1Char(' '));
                                ftsLyrics.append(ln);
                            }
                            insSection.reset();
                            insSection.bind(1, newId);
                            if (sec.label.isEmpty()) insSection.bindNull(2);
                            else                     insSection.bind(2, sec.label);
                            insSection.bind(3, labelToKind(sec.label));
                            insSection.bind(4, linesToJson(dslLines));
                            insSection.bind(5, s);
                            insSection.step();
                        }

                        // Contentless FTS5 row for this song.
                        insFts.reset();
                        insFts.bind(1, newId);
                        insFts.bind(2, title);
                        insFts.bind(3, author);
                        insFts.bind(4, ftsLyrics);
                        insFts.step();

                        ++imported;
                    }
                }

                const int pct = total > 0 ? int(100.0 * processed / total) : 100;
                if (pct != lastPct) {
                    lastPct = pct;
                    emit progress(pct, QStringLiteral("Importing songs (%1 of %2)...")
                                            .arg(processed).arg(total));
                }
            }

            tx.commit();
            emit progress(100, QStringLiteral("Finishing up..."));
            emit completed(imported, skipped);
        } catch (const db::Error& e) {
            emit failed(e.message());
        } catch (...) {
            emit failed(QStringLiteral("Unexpected error during import."));
        }
    });
}

}  // namespace crater
