#include "crater/PresentationService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QVariantMap>

namespace crater {

namespace {

// Cap slides per deck. Not a storage limit — a guard on the one operation
// that could otherwise pin the UI thread, since saveSlides() serializes the
// whole deck on every save and the editor saves on close. A sermon with more
// than this many slides is a data-entry accident, not a service.
constexpr int kMaxSlides = 500;

// Cap per-field length for the same reason. Generous enough for a full
// paragraph of body text; small enough that a paste of an entire document
// into one slide cannot produce a multi-megabyte JSON column.
constexpr int kMaxFieldChars = 20000;

// A layout id is a short slug naming which of the theme's designs this
// slide is drawn with (see docs/theme-schema.md §10). Clamped far shorter
// than a content field: it is an identifier, not prose, and a runaway value
// here would be stored on every slide of every deck.
constexpr int kMaxLayoutIdChars = 64;

QString clampField(const QVariant& v)
{
    QString s = v.toString();
    if (s.size() > kMaxFieldChars) s.truncate(kMaxFieldChars);
    return s;
}

// The single normalization boundary. Everything QML sends passes through
// here before it becomes stored JSON, so the on-disk shape is exactly the
// known keys regardless of what a model, a paste, or a future build put in
// the map.
//
// `layout` names the theme design this slide is drawn with. It is a SOFT
// reference and deliberately not validated against any theme here: a deck
// resolves its theme through a per-deck override, then the output's
// presentation slot, then the per-kind default, and an operator may swap
// any of those mid-service. A slide therefore routinely outlives the theme
// it was authored against, and the renderer falls back to the theme's
// default layout when the named one is absent (see ThemeService::layout).
// Storing the id regardless means swapping BACK restores the design.
//
// An empty `layout` means "the theme's default", which is what every slide
// written before v3 reads as.
//
// `subtitle` / `bodyRight` are the extra text slots two-column and
// title-slide designs bind; `mediaId` is the picture a picture design
// shows. All are optional — a design that declares no such node simply
// never reads them, and the editor derives which fields to offer from the
// layout's nodes rather than from anything stored here.
QString slidesToJson(const QVariantList& slides)
{
    QJsonArray arr;
    const int n = qMin(slides.size(), kMaxSlides);
    for (int i = 0; i < n; ++i) {
        const QVariantMap m = slides.at(i).toMap();
        QString layout = m.value(QStringLiteral("layout")).toString();
        if (layout.size() > kMaxLayoutIdChars) layout.truncate(kMaxLayoutIdChars);

        QJsonObject o;
        o.insert(QStringLiteral("title"),     clampField(m.value(QStringLiteral("title"))));
        o.insert(QStringLiteral("body"),      clampField(m.value(QStringLiteral("body"))));
        o.insert(QStringLiteral("notes"),     clampField(m.value(QStringLiteral("notes"))));
        o.insert(QStringLiteral("layout"),    layout);
        o.insert(QStringLiteral("subtitle"),  clampField(m.value(QStringLiteral("subtitle"))));
        o.insert(QStringLiteral("bodyRight"), clampField(m.value(QStringLiteral("bodyRight"))));
        o.insert(QStringLiteral("mediaId"),
                 static_cast<qint64>(m.value(QStringLiteral("mediaId")).toLongLong()));
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QVariantList slidesFromJson(const QString& text)
{
    QVariantList out;
    if (text.isEmpty()) return out;
    const auto doc = QJsonDocument::fromJson(text.toUtf8());
    // A non-array (hand-edited DB, truncated write) reads as an empty deck.
    // The alternative — surfacing the parse failure — would leave the
    // operator with an editor that refuses to open mid-service, and the
    // recovery for that is the same retyping an empty deck already allows.
    if (!doc.isArray()) return out;
    const auto arr = doc.array();
    for (const auto& v : arr) {
        if (!v.isObject()) continue;
        const auto o = v.toObject();
        QVariantMap m;
        // Every key is read with a default so a pre-v3 deck — which has
        // only title/body/notes on disk — loads with the new slots empty
        // rather than absent. QML reads `slide.subtitle` either way.
        m.insert(QStringLiteral("title"),     o.value(QStringLiteral("title")).toString());
        m.insert(QStringLiteral("body"),      o.value(QStringLiteral("body")).toString());
        m.insert(QStringLiteral("notes"),     o.value(QStringLiteral("notes")).toString());
        m.insert(QStringLiteral("layout"),    o.value(QStringLiteral("layout")).toString());
        m.insert(QStringLiteral("subtitle"),  o.value(QStringLiteral("subtitle")).toString());
        m.insert(QStringLiteral("bodyRight"), o.value(QStringLiteral("bodyRight")).toString());
        // toInteger, not toDouble: QJsonValue stores every number as a
        // double, and toDouble would silently round a large row id.
        m.insert(QStringLiteral("mediaId"),
                 o.value(QStringLiteral("mediaId")).toInteger(0));
        out.append(m);
    }
    return out;
}

// Slide count without a full parse of every deck. The library list reads it
// for every row on every refresh; running QJsonDocument over each deck to
// learn a single integer is work the list does not need. Stored in its own
// column and kept in step by every write path below.
int countSlides(const QString& json)
{
    const auto doc = QJsonDocument::fromJson(json.toUtf8());
    return doc.isArray() ? doc.array().size() : 0;
}

}  // namespace

struct PresentationService::Impl
{
    db::Connection conn;

    db::Statement selectAll;
    db::Statement selectOne;
    db::Statement selectSlides;
    db::Statement insertDeck;
    db::Statement renameDeck;
    db::Statement updateSlides;
    db::Statement updateThemeId;
    db::Statement deleteDeck;

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("PresentationService"))
        , selectAll(conn.prepare(QStringLiteral(
            "SELECT id, title, slide_count, theme_id, updated_at "
            "FROM presentations ORDER BY updated_at DESC, id DESC")))
        , selectOne(conn.prepare(QStringLiteral(
            "SELECT id, title, slide_count, theme_id, updated_at "
            "FROM presentations WHERE id = ?1 LIMIT 1")))
        , selectSlides(conn.prepare(QStringLiteral(
            "SELECT slides_json FROM presentations WHERE id = ?1 LIMIT 1")))
        , insertDeck(conn.prepare(QStringLiteral(
            "INSERT INTO presentations "
            "(title, slides_json, slide_count, theme_id, created_at, updated_at) "
            "VALUES (?1, ?2, ?3, ?4, ?5, ?5)")))
        , renameDeck(conn.prepare(QStringLiteral(
            "UPDATE presentations SET title = ?1, updated_at = ?2 WHERE id = ?3")))
        , updateSlides(conn.prepare(QStringLiteral(
            "UPDATE presentations SET slides_json = ?1, slide_count = ?2, updated_at = ?3 "
            "WHERE id = ?4")))
        , updateThemeId(conn.prepare(QStringLiteral(
            "UPDATE presentations SET theme_id = ?1, updated_at = ?2 WHERE id = ?3")))
        , deleteDeck(conn.prepare(QStringLiteral(
            "DELETE FROM presentations WHERE id = ?1")))
    {}
};

PresentationService::PresentationService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::appDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "PresentationService: failed to open DB —" << e.message();
    }
}

PresentationService::~PresentationService() = default;

QList<Presentation> PresentationService::presentations()
{
    QList<Presentation> out;
    if (!m_impl) return out;
    try {
        auto& stmt = m_impl->selectAll;
        stmt.reset();
        while (stmt.step()) {
            Presentation p;
            p.id         = stmt.columnInt64(0);
            p.title      = stmt.columnText(1);
            p.slideCount = stmt.columnInt(2);
            p.themeId    = stmt.columnInt64(3);
            p.updatedAt  = stmt.columnInt64(4);
            out.append(std::move(p));
        }
        stmt.reset();
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::presentations():" << e.message();
    }
    return out;
}

Presentation PresentationService::presentation(qint64 id)
{
    Presentation p;
    if (!m_impl || id <= 0) return p;
    try {
        auto& stmt = m_impl->selectOne;
        stmt.reset();
        stmt.bind(1, id);
        if (stmt.step()) {
            p.id         = stmt.columnInt64(0);
            p.title      = stmt.columnText(1);
            p.slideCount = stmt.columnInt(2);
            p.themeId    = stmt.columnInt64(3);
            p.updatedAt  = stmt.columnInt64(4);
        }
        stmt.reset();
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::presentation():" << e.message();
    }
    return p;
}

QVariantList PresentationService::slides(qint64 id)
{
    QVariantList out;
    if (!m_impl || id <= 0) return out;
    try {
        auto& stmt = m_impl->selectSlides;
        stmt.reset();
        stmt.bind(1, id);
        if (stmt.step()) out = slidesFromJson(stmt.columnText(0));
        // Reset after reading too: a live cursor pins this connection's WAL
        // snapshot and the next write fails with SQLITE_BUSY. See the note
        // on db::Statement.
        stmt.reset();
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::slides():" << e.message();
    }
    return out;
}

qint64 PresentationService::create(QString title)
{
    if (!m_impl) return 0;
    const QString t = title.trimmed();
    if (t.isEmpty()) return 0;
    try {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        // One blank slide, so the editor opens on a typeable slide rather
        // than an empty list. A deck with zero slides is also unprojectable
        // (goLive would have no pages), which is a confusing thing to be
        // able to create.
        QVariantList seed;
        seed.append(QVariantMap{
            { QStringLiteral("title"), QString() },
            { QStringLiteral("body"),  QString() },
            { QStringLiteral("notes"), QString() },
        });
        const QString json = slidesToJson(seed);

        auto& stmt = m_impl->insertDeck;
        stmt.reset();
        stmt.bind(1, t);
        stmt.bind(2, json);
        stmt.bind(3, countSlides(json));
        stmt.bind(4, static_cast<qint64>(0));
        stmt.bind(5, now);
        stmt.step();
        stmt.reset();
        const qint64 id = m_impl->conn.lastInsertRowId();
        emit presentationsChanged();
        return id;
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::create():" << e.message();
        return 0;
    }
}

bool PresentationService::rename(qint64 id, QString title)
{
    if (!m_impl || id <= 0) return false;
    const QString t = title.trimmed();
    if (t.isEmpty()) return false;
    try {
        auto& stmt = m_impl->renameDeck;
        stmt.reset();
        stmt.bind(1, t);
        stmt.bind(2, QDateTime::currentMSecsSinceEpoch());
        stmt.bind(3, id);
        stmt.step();
        stmt.reset();
        emit presentationsChanged();
        return true;
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::rename():" << e.message();
        return false;
    }
}

bool PresentationService::saveSlides(qint64 id, QVariantList slides)
{
    if (!m_impl || id <= 0) return false;
    try {
        const QString json = slidesToJson(slides);
        auto& stmt = m_impl->updateSlides;
        stmt.reset();
        stmt.bind(1, json);
        stmt.bind(2, countSlides(json));
        stmt.bind(3, QDateTime::currentMSecsSinceEpoch());
        stmt.bind(4, id);
        stmt.step();
        stmt.reset();
        emit presentationsChanged();
        return true;
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::saveSlides():" << e.message();
        return false;
    }
}

void PresentationService::setThemeId(qint64 id, qint64 themeId)
{
    if (!m_impl || id <= 0) return;
    try {
        auto& stmt = m_impl->updateThemeId;
        stmt.reset();
        stmt.bind(1, themeId);
        stmt.bind(2, QDateTime::currentMSecsSinceEpoch());
        stmt.bind(3, id);
        stmt.step();
        stmt.reset();
        emit presentationsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::setThemeId():" << e.message();
    }
}

qint64 PresentationService::duplicate(qint64 id)
{
    if (!m_impl || id <= 0) return 0;
    try {
        db::Transaction tx(m_impl->conn);

        QString title;
        QString json;
        qint64  themeId = 0;
        {
            auto& s = m_impl->selectOne;
            s.reset();
            s.bind(1, id);
            if (!s.step()) { s.reset(); return 0; }
            title   = s.columnText(1);
            themeId = s.columnInt64(3);
            s.reset();
        }
        {
            auto& s = m_impl->selectSlides;
            s.reset();
            s.bind(1, id);
            if (s.step()) json = s.columnText(0);
            s.reset();
        }

        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        auto& ins = m_impl->insertDeck;
        ins.reset();
        ins.bind(1, title + QStringLiteral(" copy"));
        ins.bind(2, json);
        ins.bind(3, countSlides(json));
        ins.bind(4, themeId);
        ins.bind(5, now);
        ins.step();
        ins.reset();
        const qint64 newId = m_impl->conn.lastInsertRowId();

        tx.commit();
        emit presentationsChanged();
        return newId;
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::duplicate():" << e.message();
        return 0;
    }
}

void PresentationService::destroy(qint64 id)
{
    if (!m_impl || id <= 0) return;
    try {
        auto& stmt = m_impl->deleteDeck;
        stmt.reset();
        stmt.bind(1, id);
        stmt.step();
        stmt.reset();
        emit presentationsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "PresentationService::destroy():" << e.message();
    }
}

}  // namespace crater
