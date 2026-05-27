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

constexpr int kAutoSaveIntervalMs  = 5000;
constexpr int kMaxHistoryFiles     = 10;
constexpr const char* kLoadedKvKey = "loaded_schedule_id";

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

    QJsonArray items;
    qint64     loadedScheduleId   = 0;
    QString    loadedScheduleName;
    std::optional<QList<SavedSchedule>> savedCache;

    // Cached prepared statements. Declared in the order they're constructed
    // in the initializer list (members are initialized in declaration order
    // regardless of how the init list is written, so keeping the two aligned
    // avoids surprise reorderings when sqlite3 sees a prepare against a half-
    // initialized connection).
    db::Statement loadCurrent;
    db::Statement updateCurrentRow;
    db::Statement listSaved;
    db::Statement insertSaved;
    db::Statement updateSaved;
    db::Statement renameSaved;
    db::Statement loadSchedule;
    db::Statement nameForId;
    db::Statement deleteSavedStmt;
    db::Statement kvGet;
    db::Statement kvSet;
    db::Statement kvDel;

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("ScheduleService"))
        , loadCurrent(conn.prepare(QStringLiteral(
            "SELECT items_json FROM current_schedule WHERE id = 1")))
        , updateCurrentRow(conn.prepare(QStringLiteral(
            "UPDATE current_schedule SET items_json = ?, modified_at = ? WHERE id = 1")))
        , listSaved(conn.prepare(QStringLiteral(
            "SELECT id, name, item_count, modified_at FROM schedules "
            "ORDER BY modified_at DESC")))
        , insertSaved(conn.prepare(QStringLiteral(
            "INSERT INTO schedules (name, items_json, item_count, created_at, modified_at) "
            "VALUES (?, ?, ?, ?, ?)")))
        , updateSaved(conn.prepare(QStringLiteral(
            "UPDATE schedules SET items_json = ?, item_count = ?, modified_at = ? "
            "WHERE id = ?")))
        , renameSaved(conn.prepare(QStringLiteral(
            "UPDATE schedules SET name = ?, modified_at = ? WHERE id = ?")))
        , loadSchedule(conn.prepare(QStringLiteral(
            "SELECT items_json FROM schedules WHERE id = ?")))
        , nameForId(conn.prepare(QStringLiteral(
            "SELECT name FROM schedules WHERE id = ?")))
        , deleteSavedStmt(conn.prepare(QStringLiteral(
            "DELETE FROM schedules WHERE id = ?")))
        , kvGet(conn.prepare(QStringLiteral(
            "SELECT value FROM kv WHERE key = ?")))
        , kvSet(conn.prepare(QStringLiteral(
            "INSERT INTO kv (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value")))
        , kvDel(conn.prepare(QStringLiteral(
            "DELETE FROM kv WHERE key = ?")))
    {
        // Restore working items from the singleton row.
        loadCurrent.reset();
        if (loadCurrent.step()) {
            const QByteArray json = loadCurrent.columnText(0).toUtf8();
            const auto doc = QJsonDocument::fromJson(json);
            if (doc.isArray()) items = doc.array();
        }

        // Restore the loaded-schedule pointer. If the row no longer exists
        // (operator deleted it while the app was closed), drop the kv entry
        // so we don't keep referencing a phantom.
        kvGet.reset();
        kvGet.bind(1, QString::fromLatin1(kLoadedKvKey));
        if (kvGet.step()) {
            const qint64 sid = kvGet.columnText(0).toLongLong();
            if (sid > 0) {
                nameForId.reset();
                nameForId.bind(1, sid);
                if (nameForId.step()) {
                    loadedScheduleId   = sid;
                    loadedScheduleName = nameForId.columnText(0);
                } else {
                    kvDel.reset();
                    kvDel.bind(1, QString::fromLatin1(kLoadedKvKey));
                    kvDel.step();
                }
            }
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
        // Last-gasp save before destruction (e.g. app shutdown). Bypass
        // setDirty() so we don't emit signals during teardown.
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

qint64  ScheduleService::loadedScheduleId()   const { return m_impl ? m_impl->loadedScheduleId   : 0;       }
QString ScheduleService::loadedScheduleName() const { return m_impl ? m_impl->loadedScheduleName : QString(); }
bool    ScheduleService::isDirty()            const { return m_impl ? m_impl->dirty              : false;   }

void ScheduleService::addItem(QVariantMap item)
{
    if (!m_impl) return;
    if (!item.contains(QStringLiteral("id"))
        || item.value(QStringLiteral("id")).toString().isEmpty()) {
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
    QJsonValue val = m_impl->items.takeAt(from);
    m_impl->items.insert(to, val);
    markDirty();
    emit currentItemsChanged();
}

void ScheduleService::clearAll()
{
    if (!m_impl) return;
    const bool hadItems  = !m_impl->items.isEmpty();
    const bool hadLoaded = m_impl->loadedScheduleId != 0;
    if (!hadItems && !hadLoaded) return;

    m_impl->items = {};
    setLoaded(0, QString());      // drop the pointer; we're starting fresh
    setDirty(false);              // an empty untitled schedule is, by definition, clean
    try { saveCurrentNow(); } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::clearAll() persist:" << e.message();
    }
    emit currentItemsChanged();
}

void ScheduleService::setItemTheme(int index, qint64 themeId)
{
    if (!m_impl || index < 0 || index >= m_impl->items.size()) return;
    QJsonObject obj = m_impl->items[index].toObject();
    if (themeId > 0) obj.insert(QStringLiteral("themeId"), themeId);
    else             obj.remove(QStringLiteral("themeId"));
    m_impl->items[index] = obj;
    markDirty();
    emit currentItemsChanged();
}

qint64 ScheduleService::saveAs(QString name)
{
    if (!m_impl) return 0;
    try {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        const QByteArray json = QJsonDocument(m_impl->items).toJson(QJsonDocument::Compact);

        auto& stmt = m_impl->insertSaved;
        stmt.reset();
        stmt.bind(1, name);
        stmt.bind(2, QString::fromUtf8(json));
        stmt.bind(3, qint64(m_impl->items.size()));
        stmt.bind(4, nowMs);
        stmt.bind(5, nowMs);
        stmt.step();

        const qint64 newId = m_impl->conn.lastInsertRowId();
        setLoaded(newId, name);
        setDirty(false);
        m_impl->savedCache.reset();
        emit savedSchedulesChanged();
        return newId;
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::saveAs():" << e.message();
        return 0;
    }
}

bool ScheduleService::saveCurrent()
{
    if (!m_impl || m_impl->loadedScheduleId <= 0) return false;
    try {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        const QByteArray json = QJsonDocument(m_impl->items).toJson(QJsonDocument::Compact);

        auto& stmt = m_impl->updateSaved;
        stmt.reset();
        stmt.bind(1, QString::fromUtf8(json));
        stmt.bind(2, qint64(m_impl->items.size()));
        stmt.bind(3, nowMs);
        stmt.bind(4, m_impl->loadedScheduleId);
        stmt.step();
        setDirty(false);
        m_impl->savedCache.reset();
        emit savedSchedulesChanged();
        return true;
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::saveCurrent():" << e.message();
        return false;
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

        // Round-trip to fetch the name. We could thread the name through
        // every load() call site, but the round-trip is sub-ms and keeps
        // the entry points self-describing.
        auto& nameStmt = m_impl->nameForId;
        nameStmt.reset();
        nameStmt.bind(1, scheduleId);
        QString name;
        if (nameStmt.step()) name = nameStmt.columnText(0);
        setLoaded(scheduleId, name);
        setDirty(false);

        // Persist the loaded items to the singleton row immediately so that
        // a crash before the next auto-save tick doesn't leave current_schedule
        // out of sync with what the operator just opened.
        try { saveCurrentNow(); } catch (const db::Error& e) {
            qWarning().noquote() << "ScheduleService::load() persist:" << e.message();
        }
        emit currentItemsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::load():" << e.message();
    }
}

void ScheduleService::rename(qint64 scheduleId, QString newName)
{
    if (!m_impl || newName.trimmed().isEmpty()) return;
    try {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        auto& stmt = m_impl->renameSaved;
        stmt.reset();
        stmt.bind(1, newName);
        stmt.bind(2, nowMs);
        stmt.bind(3, scheduleId);
        stmt.step();
        if (scheduleId == m_impl->loadedScheduleId) {
            // Re-emit loadedScheduleChanged so QML name bindings refresh.
            setLoaded(scheduleId, newName);
        }
        m_impl->savedCache.reset();
        emit savedSchedulesChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::rename():" << e.message();
    }
}

void ScheduleService::deleteSaved(qint64 scheduleId)
{
    if (!m_impl) return;
    try {
        auto& stmt = m_impl->deleteSavedStmt;
        stmt.reset();
        stmt.bind(1, scheduleId);
        stmt.step();

        if (scheduleId == m_impl->loadedScheduleId) {
            // The row we were editing was deleted. Drop the loaded pointer
            // but keep the operator's working items — they may still be
            // useful and the operator can Save As to recover identity.
            setLoaded(0, QString());
            setDirty(!m_impl->items.isEmpty());
        }
        m_impl->savedCache.reset();
        emit savedSchedulesChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::deleteSaved():" << e.message();
    }
}

void ScheduleService::closeLoaded()
{
    if (!m_impl || m_impl->loadedScheduleId == 0) return;
    setLoaded(0, QString());
    setDirty(!m_impl->items.isEmpty());
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

void ScheduleService::setDirty(bool v)
{
    if (!m_impl || m_impl->dirty == v) return;
    m_impl->dirty = v;
    emit isDirtyChanged();
}

void ScheduleService::setLoaded(qint64 id, const QString& name)
{
    if (!m_impl) return;
    const bool changed = (m_impl->loadedScheduleId != id)
                      || (m_impl->loadedScheduleName != name);
    m_impl->loadedScheduleId   = id;
    m_impl->loadedScheduleName = name;
    if (changed) {
        persistLoadedKv();
        emit loadedScheduleChanged();
    }
}

void ScheduleService::persistLoadedKv()
{
    if (!m_impl) return;
    try {
        if (m_impl->loadedScheduleId > 0) {
            auto& stmt = m_impl->kvSet;
            stmt.reset();
            stmt.bind(1, QString::fromLatin1(kLoadedKvKey));
            stmt.bind(2, QString::number(m_impl->loadedScheduleId));
            stmt.step();
        } else {
            auto& stmt = m_impl->kvDel;
            stmt.reset();
            stmt.bind(1, QString::fromLatin1(kLoadedKvKey));
            stmt.step();
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "ScheduleService::persistLoadedKv():" << e.message();
    }
}

void ScheduleService::markDirty()
{
    setDirty(true);
}

void ScheduleService::saveCurrentNow()
{
    if (!m_impl) return;
    const QByteArray json = QJsonDocument(m_impl->items).toJson(QJsonDocument::Compact);
    auto& stmt = m_impl->updateCurrentRow;
    stmt.reset();
    stmt.bind(1, QString::fromUtf8(json));
    stmt.bind(2, QDateTime::currentMSecsSinceEpoch());
    stmt.step();
    // Don't emit isDirtyChanged unconditionally — the public mutators that
    // *do* clear dirty (load / saveAs / saveCurrent / clearAll) call
    // setDirty(false) explicitly, which handles the signal + transition check.
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

    QDir d(dir);
    auto entries = d.entryInfoList(QStringList{QStringLiteral("session-*.json")},
                                    QDir::Files,
                                    QDir::Time);
    while (entries.size() > kMaxHistoryFiles) {
        QFile::remove(entries.takeLast().absoluteFilePath());
    }
}

}  // namespace crater
