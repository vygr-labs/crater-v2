#include "crater/ThemeService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>

#include <optional>

namespace crater {

namespace {

QVariantMap parseTokens(const QString& json)
{
    if (json.isEmpty()) return {};
    const auto doc = QJsonDocument::fromJson(json.toUtf8());
    if (doc.isObject()) return doc.object().toVariantMap();
    return {};
}

QString serializeTokens(const QVariantMap& tokens)
{
    return QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(tokens)).toJson(QJsonDocument::Compact));
}

}  // namespace

struct ThemeService::Impl
{
    db::Connection conn;

    db::Statement selectAll;
    db::Statement selectById;
    db::Statement insertTheme;
    db::Statement updateTheme;
    db::Statement deleteTheme;
    db::Statement selectFirstBuiltinOfKind;
    db::Statement getKv;
    db::Statement setKv;

    std::optional<QList<Theme>> cachedAll;

    explicit Impl(const QString& path)
        : conn(path)
        , selectAll(conn.prepare(QStringLiteral(
            "SELECT id, kind, name, tokens_json, is_builtin FROM themes ORDER BY kind, name")))
        , selectById(conn.prepare(QStringLiteral(
            "SELECT id, kind, name, tokens_json, is_builtin FROM themes WHERE id = ?")))
        , insertTheme(conn.prepare(QStringLiteral(
            "INSERT INTO themes (kind, name, tokens_json, is_builtin, created_at, updated_at) "
            "VALUES (?, ?, ?, 0, ?, ?)")))
        , updateTheme(conn.prepare(QStringLiteral(
            "UPDATE themes SET name = ?, tokens_json = ?, updated_at = ? WHERE id = ?")))
        , deleteTheme(conn.prepare(QStringLiteral(
            "DELETE FROM themes WHERE id = ? AND is_builtin = 0")))
        , selectFirstBuiltinOfKind(conn.prepare(QStringLiteral(
            "SELECT id, kind, name, tokens_json, is_builtin FROM themes "
            "WHERE kind = ? AND is_builtin = 1 ORDER BY id LIMIT 1")))
        , getKv(conn.prepare(QStringLiteral(
            "SELECT value FROM kv WHERE key = ?")))
        , setKv(conn.prepare(QStringLiteral(
            "INSERT INTO kv (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value")))
    {}

    Theme readRow(db::Statement& s)
    {
        Theme t;
        t.id        = s.columnInt64(0);
        t.kind      = s.columnText (1);
        t.name      = s.columnText (2);
        t.tokens    = parseTokens(s.columnText(3));
        t.isBuiltin = s.columnInt  (4) != 0;
        return t;
    }
};

ThemeService::ThemeService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::appDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "ThemeService: failed to open DB —" << e.message();
    }
}

ThemeService::~ThemeService() = default;

void ThemeService::invalidateCache()
{
    if (m_impl) m_impl->cachedAll.reset();
    emit allThemesChanged();
}

QList<Theme> ThemeService::allThemes()
{
    if (!m_impl) return {};
    if (m_impl->cachedAll) return *m_impl->cachedAll;

    QList<Theme> out;
    try {
        auto& stmt = m_impl->selectAll;
        stmt.reset();
        while (stmt.step()) out.append(m_impl->readRow(stmt));
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::allThemes():" << e.message();
    }
    m_impl->cachedAll = out;
    return out;
}

Theme ThemeService::theme(qint64 id)
{
    Theme t;
    if (!m_impl) return t;
    try {
        auto& stmt = m_impl->selectById;
        stmt.reset();
        stmt.bind(1, id);
        if (stmt.step()) t = m_impl->readRow(stmt);
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::theme():" << e.message();
    }
    return t;
}

Theme ThemeService::defaultFor(QString kind)
{
    Theme t;
    if (!m_impl) return t;
    try {
        // 1. Look up user-set default in kv.
        const QString kvKey = QStringLiteral("default_%1_theme_id").arg(kind);
        auto& kv = m_impl->getKv;
        kv.reset();
        kv.bind(1, kvKey);
        if (kv.step()) {
            bool ok = false;
            const qint64 id = kv.columnText(0).toLongLong(&ok);
            if (ok) {
                t = theme(id);
                if (t.id != 0 && t.kind == kind) return t;
            }
        }
        // 2. Fall back to first built-in of this kind.
        auto& fallback = m_impl->selectFirstBuiltinOfKind;
        fallback.reset();
        fallback.bind(1, kind);
        if (fallback.step()) t = m_impl->readRow(fallback);
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::defaultFor():" << e.message();
    }
    return t;
}

void ThemeService::setDefaultFor(QString kind, qint64 themeId)
{
    if (!m_impl) return;
    try {
        const QString kvKey = QStringLiteral("default_%1_theme_id").arg(kind);
        auto& stmt = m_impl->setKv;
        stmt.reset();
        stmt.bind(1, kvKey);
        stmt.bind(2, QString::number(themeId));
        stmt.step();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::setDefaultFor():" << e.message();
    }
}

qint64 ThemeService::create(QString kind, QString name, QVariantMap tokens)
{
    if (!m_impl) return 0;
    try {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        auto& stmt = m_impl->insertTheme;
        stmt.reset();
        stmt.bind(1, kind);
        stmt.bind(2, name);
        stmt.bind(3, serializeTokens(tokens));
        stmt.bind(4, nowMs);
        stmt.bind(5, nowMs);
        stmt.step();
        const qint64 id = m_impl->conn.lastInsertRowId();
        invalidateCache();
        return id;
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::create():" << e.message();
        return 0;
    }
}

void ThemeService::update(qint64 id, QString name, QVariantMap tokens)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->updateTheme;
        stmt.reset();
        stmt.bind(1, name);
        stmt.bind(2, serializeTokens(tokens));
        stmt.bind(3, QDateTime::currentMSecsSinceEpoch());
        stmt.bind(4, id);
        stmt.step();
        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::update():" << e.message();
    }
}

void ThemeService::destroy(qint64 id)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->deleteTheme;
        stmt.reset();
        stmt.bind(1, id);
        stmt.step();
        if (m_impl->conn.changes() > 0) invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::destroy():" << e.message();
    }
}

}  // namespace crater
