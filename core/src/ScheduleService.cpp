#include "crater/ScheduleService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QTimer>
#include <QUuid>

#include <algorithm>
#include <optional>

namespace crater {

namespace {

constexpr int kAutoSaveIntervalMs = 5000;
constexpr int kMaxHistoryFiles     = 10;

QJsonArray toJsonArray(const QVariantList& list)
{
    return QJsonArray::fromVariantList(list);
}

QVariantList toVariantList(const QJsonArray& arr)
{
    QVariantList out;
    out.reserve(arr.size());
    for (const auto& v : arr) out.append(v.toVariant());
    return out;
}

}  // namespace

struct ScheduleService::Impl
{
    db::Connection conn;
    QTimer  autoSaveTimer;
    bool    dirty = false;
    bool    historyBackedUpThisSession = false;

    QJsonArray items;            // current_schedule items
    std::optional<QList<SavedSchedule>> savedCache;

    // Cached prepared statements.
    db::Statement loadCurrent;
    db::Statement saveCurrent;
    db::Statement listSaved;
    db::Statement saveSchedule;
    db::Statement loadSchedule;
    db::Statement deleteSaved;

    explicit Impl(const QString& path)
        : conn(path)
        , loadCurrent(conn.prepare(QStringLiteral(
            "SELECT items_json FROM current_schedule WHERE id = 1")))
        , saveCurrent(conn.prepare(QStringLiteral(
            "UPDATE current_schedule SET items_json = ?, modified_at = ? WHERE id = 1")))
        , listSaved(conn.prepare(QStringLiteral(
            "SELECT id, name, item_count, modified_at FROM schedules "
            "ORDER BY modified_at DESC")))
        , saveSchedule(conn.prepare(QStringLiteral(
            "INSERT INTO schedules (name, items_json, item_count, created_at, modified_at) "
            "VALUES (?, ?, ?, ?, ?)")))
        , loadSchedule(conn.prepare(QStringLiteral(
            "SELECT items_json FROM schedules WHERE id = ?")))
        , deleteSaved(conn.prepare(QStringLiteral(
            "DELETE FROM schedules WHERE id = ?")))
    {
        // Read current_schedule from DB on construction.
        loadCurrent.reset();
        if (loadCurrent.step()) {
            const QByteArray json = loadCurrent.columnText(0).toUtf8();
            const auto doc = QJsonDocument::fromJson(json);
            if (doc.isArray()) items = doc.array();
        }
    }
};

ScheduleService::ScheduleService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::appDbPath());

        m_impl->autoSaveTimer.setInterval(kAutoSaveIntervalMs);
        m_impl->autoSaveTimer.setSingleShot(false);
        connect(&m_impl->autoSaveTimer, &QTimer::timeout,
                this, &ScheduleService::onAutoSaveTick);
        m_impl->autoSaveTimer.start();
    } catch (const db::Error& e) {
        qCritical().noquote() << "ScheduleService: failed to open DB —" << e.message();
    }
}

ScheduleService::~ScheduleService()
{
    if (m_impl && m_impl->dirty) {
        // Last-gasp save before destruction (e.g. app shutdown).
        try { saveCurrentNow(); } catch (...) { /* swallow on shutdown */ }
    }
}

QVariantList ScheduleService::currentItems() const
{
    if (!m_impl) return {};
    return toVariantList(m_impl->items);
}

QList<SavedSchedule> ScheduleService::savedSchedules()
{
    if (!m_impl) return {};
    if (m_impl->savedCache) return *m_impl->savedCache;

    QList<SavedSchedule> out;
    try {
        auto& stmt = m_impl->listSaved;
        stmt.reset();
        while (stmt.step()) {
            SavedSchedule s;
            s.id         = stmt.columnInt64(0);
            s.name       = stmt.columnText (1);
            s.itemCount  = stmt.columnInt  (2);
            s.modifiedAt = stmt.columnInt64(3);
            out.append(std::move(s));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::savedSchedules():" << e.message();
    }
    m_impl->savedCache = out;
    return out;
}

void ScheduleService::addItem(QVariantMap item)
{
    if (!m_impl) return;

    // Assign a stable opaque ID if the caller didn't supply one. QML callers
    // rarely care about ID — the service owns identity for items it holds.
    if (!item.contains(QStringLiteral("id")) || item.value(QStringLiteral("id")).toString().isEmpty()) {
        item[QStringLiteral("id")] = QUuid::createUuid().toString(QUuid::WithoutBraces);
    }

    m_impl->items.append(QJsonValue::fromVariant(item));
    markDirty();
    emit currentItemsChanged();
}

void ScheduleService::removeAt(int index)
{
    if (!m_impl || index < 0 || index >= m_impl->items.size()) return;
    m_impl->items.removeAt(index);
    markDirty();
    emit currentItemsChanged();
}

void ScheduleService::moveItem(int from, int to)
{
    if (!m_impl) return;
    if (from < 0 || from >= m_impl->items.size()) return;
    if (to   < 0 || to   >= m_impl->items.size()) return;
    if (from == to) return;

    // QJsonArray has no native move; do it manually.
    QJsonValue val = m_impl->items.takeAt(from);
    m_impl->items.insert(to, val);
    markDirty();
    emit currentItemsChanged();
}

void ScheduleService::clearAll()
{
    if (!m_impl) return;
    if (m_impl->items.isEmpty()) return;
    m_impl->items = {};
    markDirty();
    emit currentItemsChanged();
}

qint64 ScheduleService::saveAs(QString name)
{
    if (!m_impl) return 0;
    try {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        const QByteArray json = QJsonDocument(m_impl->items).toJson(QJsonDocument::Compact);

        auto& stmt = m_impl->saveSchedule;
        stmt.reset();
        stmt.bind(1, name);
        stmt.bind(2, QString::fromUtf8(json));
        stmt.bind(3, qint64(m_impl->items.size()));
        stmt.bind(4, nowMs);
        stmt.bind(5, nowMs);
        stmt.step();

        m_impl->savedCache.reset();
        emit savedSchedulesChanged();
        return m_impl->conn.lastInsertRowId();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::saveAs():" << e.message();
        return 0;
    }
}

void ScheduleService::load(qint64 scheduleId)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->loadSchedule;
        stmt.reset();
        stmt.bind(1, scheduleId);
        if (!stmt.step()) return;

        const QByteArray json = stmt.columnText(0).toUtf8();
        const auto doc = QJsonDocument::fromJson(json);
        m_impl->items = doc.isArray() ? doc.array() : QJsonArray{};
        markDirty();
        emit currentItemsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::load():" << e.message();
    }
}

void ScheduleService::deleteSaved(qint64 scheduleId)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->deleteSaved;
        stmt.reset();
        stmt.bind(1, scheduleId);
        stmt.step();
        m_impl->savedCache.reset();
        emit savedSchedulesChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::deleteSaved():" << e.message();
    }
}

void ScheduleService::onAutoSaveTick()
{
    if (!m_impl || !m_impl->dirty) return;
    try {
        backupHistoryOnce();
        saveCurrentNow();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService auto-save:" << e.message();
    }
}

void ScheduleService::markDirty()
{
    if (m_impl) m_impl->dirty = true;
}

void ScheduleService::saveCurrentNow()
{
    if (!m_impl) return;
    const QByteArray json = QJsonDocument(m_impl->items).toJson(QJsonDocument::Compact);
    auto& stmt = m_impl->saveCurrent;
    stmt.reset();
    stmt.bind(1, QString::fromUtf8(json));
    stmt.bind(2, QDateTime::currentMSecsSinceEpoch());
    stmt.step();
    m_impl->dirty = false;
}

void ScheduleService::backupHistoryOnce()
{
    if (!m_impl || m_impl->historyBackedUpThisSession) return;
    m_impl->historyBackedUpThisSession = true;

    const QString dir = db::DbPaths::scheduleHistoryDir();
    const QString ts  = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss"));
    const QString path = QDir(dir).filePath(QStringLiteral("session-%1.json").arg(ts));

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning().noquote() << "ScheduleService: could not write history backup:" << path;
        return;
    }
    f.write(QJsonDocument(m_impl->items).toJson(QJsonDocument::Indented));
    f.close();

    // Trim to last `kMaxHistoryFiles` by mtime.
    QDir d(dir);
    auto entries = d.entryInfoList(QStringList{QStringLiteral("session-*.json")},
                                    QDir::Files,
                                    QDir::Time);
    while (entries.size() > kMaxHistoryFiles) {
        QFile::remove(entries.takeLast().absoluteFilePath());
    }
}

}  // namespace crater
