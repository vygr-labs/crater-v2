#include "crater/ProjectionService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"

#include <QDebug>
#include <QVariantList>

namespace crater {

namespace {
constexpr auto kLogoBgPathKey = "projection.logoBgPath";
constexpr auto kLogoBgKindKey = "projection.logoBgKind";
}

// kv-table-backed persistence for projection state that needs to survive a
// restart. Today: just the logo background path. Held in a separate struct so
// the header stays free of <Connection> includes.
struct ProjectionService::KvImpl
{
    db::Connection conn;
    db::Statement  selectStmt;
    db::Statement  upsertStmt;

    explicit KvImpl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("ProjectionService"))
        , selectStmt(conn.prepare(QStringLiteral(
            "SELECT value FROM kv WHERE key = ?")))
        , upsertStmt(conn.prepare(QStringLiteral(
            "INSERT INTO kv (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value")))
    {}

    QString get(const QString& key)
    {
        selectStmt.reset();
        selectStmt.bind(1, key);
        QString value;
        if (selectStmt.step()) value = selectStmt.columnText(0);
        selectStmt.reset();   // close cursor: set() writes on this same
                              // connection, and an open SELECT would pin its
                              // WAL snapshot and fail that write.
        return value;
    }

    void set(const QString& key, const QString& value)
    {
        upsertStmt.reset();
        upsertStmt.bind(1, key);
        upsertStmt.bind(2, value);
        upsertStmt.step();
    }
};

ProjectionService::ProjectionService(QObject* parent)
    : QObject(parent)
{
    try {
        m_kv = std::make_unique<KvImpl>(db::DbPaths::appDbPath());
        m_logoBgPath = m_kv->get(QString::fromLatin1(kLogoBgPathKey));
        m_logoBgKind = m_kv->get(QString::fromLatin1(kLogoBgKindKey));
        // Forward-compat: pre-kind kv rows have a path but no kind. Default
        // to "image" since that was the only supported case before. The
        // first setLogoBg() call rewrites both rows so this branch only
        // ever runs once.
        if (!m_logoBgPath.isEmpty() && m_logoBgKind.isEmpty()) {
            m_logoBgKind = QStringLiteral("image");
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "ProjectionService: kv open failed —" << e.message();
        // Continue without persistence; logo bg will just default to empty.
    }
}

ProjectionService::~ProjectionService() = default;

int ProjectionService::pageCount() const
{
    const auto pages = m_currentItem.value(QStringLiteral("pages")).toList();
    return pages.size();
}

void ProjectionService::goLive(QVariantMap item, int page)
{
    // Text-based commits (songs / scriptures) and the schedule-double-click
    // path don't carry a crop intent. Reset to full-frame so a prior media
    // item's stale rect can't leak into the new render. ProjectionScene
    // gates the crop on the active content kind already (text branches
    // ignore it), but resetting here keeps the cropRect property honest
    // for any future consumer that reads it without kind-gating.
    goLiveWithCrop(std::move(item), page, QRectF(0, 0, 1, 1));
}

void ProjectionService::goLiveWithCrop(QVariantMap item, int page, QRectF cropRect)
{
    m_currentItem = std::move(item);
    m_contentKind = m_currentItem.value(QStringLiteral("kind")).toString();

    const int n = pageCount();
    m_pageIndex = (n > 0) ? qBound(0, page, n - 1) : 0;
    // Clear is a sticky overlay, PRESERVED across go-live: staging new content
    // while the screen is blanked must not reveal it. m_isClear is left as-is —
    // when set, the freshly-promoted layer binds its text node to opacity 0 from
    // birth, so nothing paints. (An earlier QML attempt re-cleared *after* a
    // go-live that had reset the flag; the new layer briefly painted text at full
    // opacity and then faded it out — a visible 1-second flash. Preserving the
    // flag at the source avoids ever showing the text.) The operator lifts a
    // clear explicitly via unclear() (AppState.clearLive).

    // Clamp + sanitize. An empty or invalid rect collapses to full-frame so
    // ProjectionScene's renderer always has a valid sub-region to clip to.
    if (!cropRect.isValid() || cropRect.isEmpty()) {
        cropRect = QRectF(0, 0, 1, 1);
    }
    cropRect = cropRect.intersected(QRectF(0, 0, 1, 1));
    if (cropRect.isEmpty()) cropRect = QRectF(0, 0, 1, 1);
    m_cropRect = cropRect;

    emit stateChanged();
}

void ProjectionService::clear()
{
    if (m_isClear) return;
    m_isClear = true;
    emit stateChanged();
}

void ProjectionService::unclear()
{
    // Lift a clear without re-staging the item — the text node fades back in
    // over the existing background via NodeRenderer's clear-fade, and the live
    // crop / page / item are all untouched. Idempotent when not cleared.
    if (!m_isClear) return;
    m_isClear = false;
    emit stateChanged();
}

void ProjectionService::setPage(int i)
{
    const int n = pageCount();
    const int clamped = (n > 0) ? qBound(0, i, n - 1) : 0;
    // Page navigation is clear-agnostic: it owns only the page index. Clearing
    // is a sticky overlay the operator lifts explicitly (AppState.clearLive /
    // Ctrl+C, which re-stages via goLiveWithCrop) — advancing or rewinding
    // pages while cleared moves the hidden content underneath and the audience
    // stays blank until an explicit un-clear. Previously this set
    // m_isClear=false, which surprised operators who had intentionally blanked
    // the screen. Nothing un-clears via setPage, so dropping that is safe; the
    // guard below no longer special-cases m_isClear (same page == no-op).
    if (clamped == m_pageIndex) return;
    m_pageIndex = clamped;
    emit stateChanged();
}

void ProjectionService::nextPage() { setPage(m_pageIndex + 1); }
void ProjectionService::prevPage() { setPage(m_pageIndex - 1); }

void ProjectionService::toggleLogo()
{
    m_showLogo = !m_showLogo;
    emit stateChanged();
}

void ProjectionService::setLogoVisible(bool visible)
{
    if (m_showLogo == visible) return;
    m_showLogo = visible;
    emit stateChanged();
}

void ProjectionService::setLogoBg(QString path, QString kind)
{
    // Empty path clears the logo; carry an empty kind through so QML's
    // `logoBgKind` binding doesn't keep a stale type.
    if (path.isEmpty()) kind.clear();

    const bool pathChanged = (path != m_logoBgPath);
    const bool kindChanged = (kind != m_logoBgKind);
    if (!pathChanged && !kindChanged) return;

    m_logoBgPath = std::move(path);
    m_logoBgKind = std::move(kind);

    if (m_kv) {
        try {
            m_kv->set(QString::fromLatin1(kLogoBgPathKey), m_logoBgPath);
            m_kv->set(QString::fromLatin1(kLogoBgKindKey), m_logoBgKind);
        } catch (const db::Error& e) {
            qWarning().noquote() << "ProjectionService::setLogoBg() persist failed:"
                                 << e.message();
        }
    }
    if (pathChanged) emit logoBgPathChanged();
    if (kindChanged) emit logoBgKindChanged();
}

}  // namespace crater
