#include "crater/ThemeService.h"

#include "bundle/Zip.h"
#include "crater/FontService.h"
#include "crater/MediaService.h"
#include "crater/Version.h"
#include "crater/value/MediaItem.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QColor>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSet>
#include <QUuid>

#include <cmath>
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

// Maps v1 layout.verticalAlignment ("top"|"center"|"bottom") to v2
// style.verticalAlign ("start"|"center"|"end"). Returns "center" on miss.
QString mapVerticalAlign(const QString& v1)
{
    if (v1 == QLatin1String("top"))    return QStringLiteral("start");
    if (v1 == QLatin1String("bottom")) return QStringLiteral("end");
    return QStringLiteral("center");
}

// Returns the default text linkage for a theme kind. song -> lyric,
// scripture -> scriptureText, presentation -> custom (with empty text).
QString defaultLinkageFor(const QString& kind)
{
    if (kind == QLatin1String("song"))      return QStringLiteral("lyric");
    if (kind == QLatin1String("scripture")) return QStringLiteral("scriptureText");
    return QStringLiteral("custom");
}

// Rewrites a v1 token shape ({background, text, layout, transition}) into
// the v2 node-based shape ({version, canvas, nodes}). The transition field
// is intentionally dropped — transitions are now a property of the
// projection layer, not the theme. Visual parity is the goal, not pixel
// parity: padding (px) becomes a 5% inset (~96px at 1920 wide).
QVariantMap buildV2FromV1(const QString& kind, const QVariantMap& v1)
{
    const auto bg     = v1.value("background").toMap();
    const auto text   = v1.value("text").toMap();
    const auto layout = v1.value("layout").toMap();

    const QString bgColor      = bg.value("color", "#0a0a0d").toString();
    const QString fontFamily   = text.value("fontFamily", "Segoe UI Variable Display").toString();
    const int     fontSize     = text.value("fontPixelSize", 64).toInt();
    const int     fontWeight   = text.value("fontWeight", 500).toInt();
    const QString fgColor      = text.value("color", "#f5f5f0").toString();
    const double  lineHeight   = text.value("lineHeightMultiplier", 1.25).toDouble();
    const double  letterSpace  = text.value("letterSpacing", 0.0).toDouble();
    const QString hAlign       = layout.value("horizontalAlignment", "center").toString();
    const QString vAlign       = mapVerticalAlign(layout.value("verticalAlignment", "center").toString());

    QVariantMap containerStyle;
    containerStyle["x"]               = 0;
    containerStyle["y"]               = 0;
    containerStyle["width"]           = 100;
    containerStyle["height"]          = 100;
    containerStyle["z"]               = 0;
    containerStyle["opacity"]         = 1;
    containerStyle["backgroundColor"] = bgColor;

    QVariantMap containerData;
    containerData["layerName"]    = QStringLiteral("Background");
    containerData["mediaId"]      = QVariant::fromValue(nullptr);
    containerData["bgOpacity"]    = 1;
    containerData["overlayColor"] = QVariant::fromValue(nullptr);

    QVariantMap container;
    container["id"]    = QStringLiteral("bg");
    container["kind"]  = QStringLiteral("container");
    container["style"] = containerStyle;
    container["data"]  = containerData;

    QVariantMap textStyle;
    textStyle["x"]                    = 5;     // 5% inset on all sides
    textStyle["y"]                    = 35;    // centered band
    textStyle["width"]                = 90;
    textStyle["height"]               = 30;
    textStyle["z"]                    = 10;
    textStyle["opacity"]              = 1;
    textStyle["color"]                = fgColor;
    textStyle["fontFamily"]           = fontFamily;
    textStyle["fontPixelSize"]        = fontSize;
    textStyle["fontWeight"]           = fontWeight;
    textStyle["lineHeightMultiplier"] = lineHeight;
    textStyle["letterSpacing"]        = letterSpace;
    textStyle["textAlign"]            = hAlign;
    textStyle["verticalAlign"]        = vAlign;

    QVariantMap textData;
    textData["layerName"]   = (kind == QLatin1String("song"))      ? QStringLiteral("Lyric")
                            : (kind == QLatin1String("scripture")) ? QStringLiteral("Verse")
                                                                   : QStringLiteral("Text");
    textData["linkage"]     = defaultLinkageFor(kind);
    textData["autoResize"]  = true;
    textData["maxFontSize"] = 220;
    if (textData.value("linkage").toString() == QLatin1String("custom"))
        textData["text"] = QString();

    QVariantMap textNode;
    textNode["id"]    = QStringLiteral("txt");
    textNode["kind"]  = QStringLiteral("text");
    textNode["style"] = textStyle;
    textNode["data"]  = textData;

    QVariantList nodes;
    nodes.append(container);
    nodes.append(textNode);

    QVariantMap canvas;
    canvas["width"]  = 1920;
    canvas["height"] = 1080;

    QVariantMap tokens;
    tokens["version"] = 2;
    tokens["canvas"]  = canvas;
    tokens["nodes"]   = nodes;
    return tokens;
}

// --- Validation -----------------------------------------------------------
//
// Hand-written validator for v2 tokens. Returns an empty list when the
// input is well-formed. Each error string is human-readable and pinned to
// the JSON path that failed ("nodes[2].style.opacity must be 0..1") so the
// editor can surface them inline. Called from importThemeFile, create,
// and update — but never during preview rendering, which must tolerate
// partial in-progress state.

bool isFiniteNumber(const QVariant& v)
{
    if (!v.canConvert<double>()) return false;
    bool ok = false;
    const double d = v.toDouble(&ok);
    return ok && std::isfinite(d);
}

bool inRange(double v, double lo, double hi) { return v >= lo && v <= hi; }

bool isHexColor(const QString& s)
{
    return QColor(s).isValid();
}

void validateStyleCommon(const QVariantMap& style, int idx, QStringList& errs)
{
    const auto must01to100 = [&](const char* field) {
        if (!isFiniteNumber(style.value(field))) {
            errs << QStringLiteral("nodes[%1].style.%2 must be a number").arg(idx).arg(field);
            return;
        }
        const double v = style.value(field).toDouble();
        if (!inRange(v, 0.0, 100.0))
            errs << QStringLiteral("nodes[%1].style.%2 must be 0..100").arg(idx).arg(field);
    };
    must01to100("x");
    must01to100("y");
    must01to100("width");
    must01to100("height");

    if (style.contains("opacity")) {
        if (!isFiniteNumber(style.value("opacity")) ||
            !inRange(style.value("opacity").toDouble(), 0.0, 1.0))
            errs << QStringLiteral("nodes[%1].style.opacity must be 0..1").arg(idx);
    }
    if (style.contains("z") && !style.value("z").canConvert<int>())
        errs << QStringLiteral("nodes[%1].style.z must be an integer").arg(idx);
    if (style.contains("rotation") && !isFiniteNumber(style.value("rotation")))
        errs << QStringLiteral("nodes[%1].style.rotation must be a finite number").arg(idx);
}

void validateTextNode(const QVariantMap& n, int idx, QStringList& errs)
{
    const auto style = n.value("style").toMap();
    const auto data  = n.value("data").toMap();

    if (!style.contains("color") || !isHexColor(style.value("color").toString()))
        errs << QStringLiteral("nodes[%1].style.color must be a valid hex color").arg(idx);

    if (style.contains("fontPixelSize") && style.value("fontPixelSize").toInt() <= 0)
        errs << QStringLiteral("nodes[%1].style.fontPixelSize must be > 0").arg(idx);

    if (style.contains("fontWeight")) {
        const int w = style.value("fontWeight").toInt();
        if (w < 100 || w > 900 || (w % 100) != 0)
            errs << QStringLiteral("nodes[%1].style.fontWeight must be 100..900 in steps of 100").arg(idx);
    }
    if (style.contains("lineHeightMultiplier") &&
        !inRange(style.value("lineHeightMultiplier").toDouble(), 0.5, 3.0))
        errs << QStringLiteral("nodes[%1].style.lineHeightMultiplier must be 0.5..3.0").arg(idx);

    if (style.contains("letterSpacing") &&
        !inRange(style.value("letterSpacing").toDouble(), -2.0, 10.0))
        errs << QStringLiteral("nodes[%1].style.letterSpacing must be -2..10").arg(idx);

    // Drop shadow — all four fields are optional. The renderer keys "is
    // shadow active?" off textShadowColor being a non-empty string, so an
    // empty string is the accepted sentinel for "shadow off" without the
    // schema needing a separate toggle boolean.
    if (style.contains("textShadowOffsetX") &&
        (!isFiniteNumber(style.value("textShadowOffsetX")) ||
         !inRange(style.value("textShadowOffsetX").toDouble(), -50.0, 50.0)))
        errs << QStringLiteral("nodes[%1].style.textShadowOffsetX must be -50..50").arg(idx);
    if (style.contains("textShadowOffsetY") &&
        (!isFiniteNumber(style.value("textShadowOffsetY")) ||
         !inRange(style.value("textShadowOffsetY").toDouble(), -50.0, 50.0)))
        errs << QStringLiteral("nodes[%1].style.textShadowOffsetY must be -50..50").arg(idx);
    if (style.contains("textShadowBlur") &&
        (!isFiniteNumber(style.value("textShadowBlur")) ||
         !inRange(style.value("textShadowBlur").toDouble(), 0.0, 50.0)))
        errs << QStringLiteral("nodes[%1].style.textShadowBlur must be 0..50").arg(idx);
    if (style.contains("textShadowColor")) {
        const QString c = style.value("textShadowColor").toString();
        if (!c.isEmpty() && !isHexColor(c))
            errs << QStringLiteral("nodes[%1].style.textShadowColor must be a valid hex color or empty").arg(idx);
    }

    static const QSet<QString> hAligns{ "left", "center", "right" };
    if (style.contains("textAlign") && !hAligns.contains(style.value("textAlign").toString()))
        errs << QStringLiteral("nodes[%1].style.textAlign must be left|center|right").arg(idx);

    static const QSet<QString> vAligns{ "start", "center", "end" };
    if (style.contains("verticalAlign") && !vAligns.contains(style.value("verticalAlign").toString()))
        errs << QStringLiteral("nodes[%1].style.verticalAlign must be start|center|end").arg(idx);

    static const QSet<QString> tCases{ "none", "uppercase", "lowercase", "capitalize" };
    if (style.contains("textTransform") && !tCases.contains(style.value("textTransform").toString()))
        errs << QStringLiteral("nodes[%1].style.textTransform must be none|uppercase|lowercase|capitalize").arg(idx);

    static const QSet<QString> linkages{ "scriptureRef", "scriptureText", "lyric", "custom" };
    if (!data.contains("linkage") || !linkages.contains(data.value("linkage").toString()))
        errs << QStringLiteral("nodes[%1].data.linkage must be scriptureRef|scriptureText|lyric|custom").arg(idx);

    if (data.value("autoResize").toBool() && data.contains("maxFontSize") &&
        data.value("maxFontSize").toInt() <= 0)
        errs << QStringLiteral("nodes[%1].data.maxFontSize must be > 0 when autoResize is true").arg(idx);
}

void validateContainerNode(const QVariantMap& n, int idx, QStringList& errs)
{
    const auto style = n.value("style").toMap();
    if (style.contains("backgroundColor")) {
        const QString c = style.value("backgroundColor").toString();
        if (!c.isEmpty() && !isHexColor(c))
            errs << QStringLiteral("nodes[%1].style.backgroundColor must be a valid hex color").arg(idx);
    }
    for (const char* corner : { "borderTopLeftRadius", "borderTopRightRadius",
                                "borderBottomLeftRadius", "borderBottomRightRadius" }) {
        if (style.contains(corner) && style.value(corner).toDouble() < 0)
            errs << QStringLiteral("nodes[%1].style.%2 must be >= 0").arg(idx).arg(corner);
    }
}

QStringList validateTokensV2(const QVariantMap& t)
{
    QStringList errs;
    if (t.value("version").toInt() != 2) {
        errs << QStringLiteral("version must be 2");
        // Don't bail — other errors are still useful for diagnostics.
    }

    const auto canvas = t.value("canvas").toMap();
    if (canvas.value("width").toInt()  <= 0) errs << QStringLiteral("canvas.width must be > 0");
    if (canvas.value("height").toInt() <= 0) errs << QStringLiteral("canvas.height must be > 0");

    const auto nodes = t.value("nodes").toList();
    if (nodes.isEmpty()) {
        errs << QStringLiteral("nodes must be a non-empty array");
        return errs;
    }

    QSet<QString> seenIds;
    for (int i = 0; i < nodes.size(); ++i) {
        const auto n = nodes[i].toMap();
        const QString id   = n.value("id").toString();
        const QString kind = n.value("kind").toString();
        if (id.isEmpty()) errs << QStringLiteral("nodes[%1].id missing").arg(i);
        else if (seenIds.contains(id))
            errs << QStringLiteral("duplicate node id: %1").arg(id);
        seenIds.insert(id);

        if (kind != QLatin1String("container") && kind != QLatin1String("text"))
            errs << QStringLiteral("nodes[%1].kind must be container|text").arg(i);

        validateStyleCommon(n.value("style").toMap(), i, errs);
        if (kind == QLatin1String("text"))      validateTextNode(n, i, errs);
        if (kind == QLatin1String("container")) validateContainerNode(n, i, errs);
    }
    return errs;
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
    db::Statement selectV1Rows;
    db::Statement updateRowToV2;
    db::Statement countByKindName;
    db::Statement selectIsBuiltin;

    std::optional<QList<Theme>> cachedAll;

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("ThemeService"))
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
        , selectV1Rows(conn.prepare(QStringLiteral(
            "SELECT id, kind, tokens_json FROM themes WHERE tokens_version < 2")))
        , updateRowToV2(conn.prepare(QStringLiteral(
            "UPDATE themes SET tokens_json = ?, tokens_version = 2, updated_at = ? "
            "WHERE id = ?")))
        , countByKindName(conn.prepare(QStringLiteral(
            "SELECT COUNT(*) FROM themes WHERE kind = ? AND name = ?")))
        , selectIsBuiltin(conn.prepare(QStringLiteral(
            "SELECT is_builtin FROM themes WHERE id = ?")))
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

    // Rewrites every row with tokens_version < 2 into v2 node-based JSON.
    // Wrapped in a single transaction; a failure mid-batch rolls back so we
    // don't get a half-migrated themes table.
    void migrateRowsToV2()
    {
        QList<std::tuple<qint64, QString, QString>> rows;  // id, kind, oldJson
        try {
            auto& sel = selectV1Rows;
            sel.reset();
            while (sel.step()) {
                rows.append({ sel.columnInt64(0), sel.columnText(1), sel.columnText(2) });
            }
        } catch (const db::Error& e) {
            qWarning().noquote() << "ThemeService::migrateRowsToV2(): SELECT failed —" << e.message();
            return;
        }
        if (rows.isEmpty()) return;

        try {
            db::Transaction tx(conn);
            const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
            for (const auto& [id, kind, oldJson] : rows) {
                const QVariantMap v1   = parseTokens(oldJson);
                const QVariantMap v2   = buildV2FromV1(kind, v1);
                const QString    json = serializeTokens(v2);

                auto& upd = updateRowToV2;
                upd.reset();
                upd.bind(1, json);
                upd.bind(2, nowMs);
                upd.bind(3, id);
                upd.step();
            }
            tx.commit();
            qInfo().noquote() << "ThemeService: migrated" << rows.size()
                              << "themes from tokens v1 -> v2";
        } catch (const db::Error& e) {
            qWarning().noquote() << "ThemeService::migrateRowsToV2(): tx failed —" << e.message();
        }
    }
};

ThemeService::ThemeService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::appDbPath());
        // Lazy v1 -> v2 token rewrite. Runs once after V003 SQL migration
        // bumps user_version + adds tokens_version column (defaulted to 1).
        m_impl->migrateRowsToV2();
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
        stmt.reset();   // close cursor: an open SELECT pins this connection's
                        // WAL snapshot, silently failing the next update() write
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
        qint64 wantId = 0;
        bool   haveId = false;
        if (kv.step()) {
            bool ok = false;
            const qint64 id = kv.columnText(0).toLongLong(&ok);
            if (ok) { wantId = id; haveId = true; }
        }
        kv.reset();   // close cursor before theme()'s query / the early return
        if (haveId) {
            t = theme(wantId);
            if (t.id != 0 && t.kind == kind) return t;
        }
        // 2. Fall back to first built-in of this kind.
        auto& fallback = m_impl->selectFirstBuiltinOfKind;
        fallback.reset();
        fallback.bind(1, kind);
        if (fallback.step()) t = m_impl->readRow(fallback);
        fallback.reset();   // release read txn
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
        emit defaultsChanged();
    } catch (const db::Error& e) {
        qWarning().noquote() << "ThemeService::setDefaultFor():" << e.message();
    }
}

qint64 ThemeService::create(QString kind, QString name, QVariantMap tokens)
{
    if (!m_impl) return 0;
    try {
        const QStringList errs = validateTokensV2(tokens);
        if (!errs.isEmpty()) {
            qWarning().noquote() << "ThemeService::create(): validation failed:"
                                 << errs.join(QStringLiteral("; "));
            return 0;
        }
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
        // Built-in protection: duplicate-then-edit, never edit in place. The
        // V001 seed rows are the contract for "what ships out of the box";
        // letting users mutate them silently breaks that contract.
        auto& isB = m_impl->selectIsBuiltin;
        isB.reset();
        isB.bind(1, id);
        const bool isBuiltin = isB.step() && isB.columnInt(0) != 0;
        isB.reset();   // close cursor: this probe runs right before the UPDATE
                       // write below. Left open, it pins this connection's WAL
                       // snapshot and the UPDATE fails with SQLITE_BUSY (517) —
                       // the silent cause of lost theme edits (e.g. video bg).
        if (isBuiltin) {
            qWarning().noquote() << "ThemeService::update(): refusing to edit built-in theme id="
                                 << id << "— duplicate it first";
            return;
        }

        const QStringList errs = validateTokensV2(tokens);
        if (!errs.isEmpty()) {
            qWarning().noquote() << "ThemeService::update(): validation failed:"
                                 << errs.join(QStringLiteral("; "));
            return;
        }

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

QStringList ThemeService::validateTokens(QVariantMap tokens)
{
    return validateTokensV2(tokens);
}

// ═══════════════════════════════════════════════════════════════════════
// Bundle (.craterheme v2) — export and import
// ═══════════════════════════════════════════════════════════════════════
//
// On-disk layout and rationale: ARCHITECTURE.md §10.
//
// One key invariant: the RUNTIME token shape never changes.
//   • On disk in the bundle:  data.mediaRef = "<sha256>",
//                             style.fontRef  = "<sha256>" (sibling of fontFamily)
//   • In the DB at runtime:   data.mediaId  = <qint64>,
//                             style.fontFamily = "Inter"   (no fontRef)
// The import path rewrites refs -> local ids before insert, so QML and
// the renderer code never see mediaRef/fontRef. See §10.6 — this is the
// load-bearing decision that keeps the bundle complexity out of the hot
// rendering path.

namespace {

constexpr int kBundleFormatVersion = 2;

// Builds a unique theme name within (kind, name) by appending " (Import)",
// " (Import 2)", … until no row matches.
QString resolveImportName(db::Statement& countStmt, const QString& kind, const QString& base)
{
    const auto exists = [&](const QString& n) -> bool {
        countStmt.reset();
        countStmt.bind(1, kind);
        countStmt.bind(2, n);
        const bool found = countStmt.step() && countStmt.columnInt(0) > 0;
        countStmt.reset();   // close cursor before the create() INSERT that follows
        return found;
    };
    if (!exists(base)) return base;
    const QString withTag = base + QStringLiteral(" (Import)");
    if (!exists(withTag)) return withTag;
    for (int i = 2; i < 1000; ++i) {
        const QString candidate = QStringLiteral("%1 (Import %2)").arg(base).arg(i);
        if (!exists(candidate)) return candidate;
    }
    return base + QStringLiteral(" (Import)");
}

QString sha256Hex(QByteArrayView bytes)
{
    return QString::fromLatin1(QCryptographicHash::hash(
        QByteArray::fromRawData(bytes.data(), bytes.size()),
        QCryptographicHash::Sha256).toHex());
}

// Walks tokens.nodes and collects every numeric mediaId that container
// nodes refer to. Skips nulls and zeros (the "no media" sentinel).
QSet<qint64> collectMediaIds(const QVariantMap& tokens)
{
    QSet<qint64> out;
    const QVariantList nodes = tokens.value(QStringLiteral("nodes")).toList();
    for (const QVariant& n : nodes) {
        const QVariantMap node = n.toMap();
        if (node.value(QStringLiteral("kind")).toString() != QLatin1String("container")) continue;
        const QVariantMap data = node.value(QStringLiteral("data")).toMap();
        const QVariant idVar = data.value(QStringLiteral("mediaId"));
        if (!idVar.isValid() || idVar.isNull()) continue;
        bool ok = false;
        const qint64 id = idVar.toLongLong(&ok);
        if (ok && id > 0) out.insert(id);
    }
    return out;
}

// Walks tokens.nodes and collects every fontFamily a text node references.
// Empty strings are skipped (text without an explicit family falls back to
// the app default).
QSet<QString> collectFontFamilies(const QVariantMap& tokens)
{
    QSet<QString> out;
    const QVariantList nodes = tokens.value(QStringLiteral("nodes")).toList();
    for (const QVariant& n : nodes) {
        const QVariantMap node = n.toMap();
        if (node.value(QStringLiteral("kind")).toString() != QLatin1String("text")) continue;
        const QVariantMap style = node.value(QStringLiteral("style")).toMap();
        const QString fam = style.value(QStringLiteral("fontFamily")).toString().trimmed();
        if (!fam.isEmpty()) out.insert(fam);
    }
    return out;
}

// Returns a deep-rewritten copy of `tokens` for ON-DISK export:
//   • container.data.mediaId N        ->  container.data.mediaRef "<hash>"
//                                         (existing mediaId removed)
//   • text.style fontFamily "Inter"   ->  unchanged, but style.fontRef "<hash>"
//                                         is added when the family is bundled
QVariantMap rewriteTokensForExport(const QVariantMap& tokens,
                                   const QHash<qint64, QString>& mediaIdToHash,
                                   const QHash<QString, QString>& fontFamilyToHash)
{
    QVariantMap out = tokens;
    QVariantList nodes = out.value(QStringLiteral("nodes")).toList();
    for (int i = 0; i < nodes.size(); ++i) {
        QVariantMap node = nodes[i].toMap();
        const QString kind = node.value(QStringLiteral("kind")).toString();
        if (kind == QLatin1String("container")) {
            QVariantMap data = node.value(QStringLiteral("data")).toMap();
            const QVariant idVar = data.value(QStringLiteral("mediaId"));
            bool ok = false;
            const qint64 id = idVar.toLongLong(&ok);
            if (ok && id > 0) {
                const auto it = mediaIdToHash.constFind(id);
                if (it != mediaIdToHash.constEnd()) {
                    data.remove(QStringLiteral("mediaId"));
                    data[QStringLiteral("mediaRef")] = it.value();
                } else {
                    // Stale reference — the row was deleted before export.
                    // We must NOT ship our local id in the bundle: on the
                    // importing machine, that integer would be interpreted
                    // as one of THEIR media rows (a number that might
                    // happen to exist and point at totally unrelated
                    // bytes). Nulling it is the only safe value.
                    data[QStringLiteral("mediaId")] = QVariant::fromValue(nullptr);
                }
            }
            node[QStringLiteral("data")] = data;
        } else if (kind == QLatin1String("text")) {
            QVariantMap style = node.value(QStringLiteral("style")).toMap();
            const QString fam = style.value(QStringLiteral("fontFamily")).toString().trimmed();
            if (!fam.isEmpty()) {
                const auto it = fontFamilyToHash.constFind(fam);
                if (it != fontFamilyToHash.constEnd()) {
                    style[QStringLiteral("fontRef")] = it.value();
                }
            }
            node[QStringLiteral("style")] = style;
        }
        nodes[i] = node;
    }
    out[QStringLiteral("nodes")] = nodes;
    return out;
}

// Returns a deep-rewritten copy of `tokens` for IMPORT into the live DB:
//   • container.data.mediaRef "<hash>"  ->  container.data.mediaId (resolved id)
//                                            or mediaId = null on miss
//   • text.style.fontRef "<hash>"        ->  removed (a hash is meaningless
//                                            at runtime); fontFamily stays
//
// The hash maps come from the bundle import — mediaRefs that fail to
// import won't be in `hashToMediaId`, and the corresponding mediaId is
// set to null. Per-asset failures are accumulated as warnings outside
// this function (see importThemeFile).
QVariantMap rewriteTokensForImport(const QVariantMap& tokens,
                                   const QHash<QString, qint64>& hashToMediaId)
{
    QVariantMap out = tokens;
    QVariantList nodes = out.value(QStringLiteral("nodes")).toList();
    for (int i = 0; i < nodes.size(); ++i) {
        QVariantMap node = nodes[i].toMap();
        const QString kind = node.value(QStringLiteral("kind")).toString();
        if (kind == QLatin1String("container")) {
            QVariantMap data = node.value(QStringLiteral("data")).toMap();
            if (data.contains(QStringLiteral("mediaRef"))) {
                const QString hash = data.value(QStringLiteral("mediaRef")).toString();
                data.remove(QStringLiteral("mediaRef"));
                const auto it = hashToMediaId.constFind(hash);
                if (it != hashToMediaId.constEnd()) {
                    data[QStringLiteral("mediaId")] = QVariant(it.value());
                } else {
                    // Bundled media failed to import — leave nodes pointing
                    // at no media, exactly the "Background" container's
                    // default state when nothing has been picked.
                    data[QStringLiteral("mediaId")] = QVariant::fromValue(nullptr);
                }
            }
            node[QStringLiteral("data")] = data;
        } else if (kind == QLatin1String("text")) {
            QVariantMap style = node.value(QStringLiteral("style")).toMap();
            // fontRef is purely an on-disk hint — strip it for runtime.
            // The fontFamily string was preserved alongside it at export,
            // so font resolution at render time works the usual way
            // (registered via FontService at startup, or system-installed).
            style.remove(QStringLiteral("fontRef"));
            node[QStringLiteral("style")] = style;
        }
        nodes[i] = node;
    }
    out[QStringLiteral("nodes")] = nodes;
    return out;
}

// QFile::readAll() wrapper that handles open-failure with a populated
// QString error rather than the caller having to interpret an empty
// QByteArray.
std::optional<QByteArray> readWholeFile(const QString& path, QString* outReason)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        if (outReason) *outReason = f.errorString();
        return std::nullopt;
    }
    QByteArray bytes = f.readAll();
    if (f.error() != QFileDevice::NoError) {
        if (outReason) *outReason = f.errorString();
        return std::nullopt;
    }
    return bytes;
}

}  // namespace

void ThemeService::setMediaService(MediaService* media) { m_media = media; }
void ThemeService::setFontService(FontService* font)    { m_fonts = font;  }

QString ThemeService::lastImportError() const { return m_lastImportError; }
QString ThemeService::lastExportError() const { return m_lastExportError; }

QVariantMap ThemeService::resolveExportPlan(qint64 id)
{
    const Theme t = theme(id);
    if (t.id == 0) return {};

    QVariantMap plan;
    plan[QStringLiteral("themeName")]  = t.name;
    plan[QStringLiteral("themeKind")]  = t.kind;
    plan[QStringLiteral("appVersion")] = versionString();

    // Media: every referenced row that still resolves becomes a bundle
    // candidate. We don't surface per-item opt-out in v1 (operator-owned
    // media isn't license-constrained the way fonts are — §10.3).
    QVariantList mediaList;
    if (m_media) {
        for (qint64 mid : collectMediaIds(t.tokens)) {
            const MediaItem item = m_media->byId(mid);
            if (item.id == 0) continue;
            const QFileInfo info(item.path);
            QVariantMap entry;
            entry[QStringLiteral("mediaId")]    = mid;
            entry[QStringLiteral("title")]      = item.title;
            entry[QStringLiteral("sourcePath")] = item.path;
            entry[QStringLiteral("sizeBytes")]  = info.size();
            entry[QStringLiteral("type")]       = item.type;
            mediaList.append(entry);
        }
    }
    plan[QStringLiteral("media")] = mediaList;

    // Fonts: split into bundleable (FontService knows a file path for
    // the family) vs systemOnly (we'll record the family name but ship
    // no bytes; importer's machine has to have it installed).
    QVariantList bundleable;
    QStringList  systemOnly;
    const QSet<QString> families = collectFontFamilies(t.tokens);
    for (const QString& fam : families) {
        QString path = m_fonts ? m_fonts->filePathForFamily(fam) : QString();
        if (path.isEmpty()) {
            systemOnly.append(fam);
            continue;
        }
        const QFileInfo info(path);
        QVariantMap entry;
        entry[QStringLiteral("family")]     = fam;
        entry[QStringLiteral("sourcePath")] = path;
        entry[QStringLiteral("sizeBytes")]  = info.size();
        bundleable.append(entry);
    }
    QVariantMap fonts;
    fonts[QStringLiteral("bundleable")] = bundleable;
    fonts[QStringLiteral("systemOnly")] = systemOnly;
    plan[QStringLiteral("fonts")] = fonts;

    return plan;
}

bool ThemeService::exportTheme(qint64       id,
                               QString      filePath,
                               QStringList  excludedFontFamilies)
{
    m_lastExportError.clear();

    const Theme t = theme(id);
    if (t.id == 0) {
        m_lastExportError = QStringLiteral("No theme with id %1").arg(id);
        return false;
    }

    // ── Resolve media files referenced by the theme ─────────────────────
    QHash<qint64, QString> mediaIdToHash;   // for token rewrite
    QHash<QString, QByteArray> mediaBytes;  // hash -> bytes (dedup'd)
    QJsonArray mediaManifest;

    if (!m_media && !collectMediaIds(t.tokens).isEmpty()) {
        m_lastExportError = QStringLiteral(
            "Theme references media but MediaService is not wired");
        return false;
    }

    for (qint64 mid : collectMediaIds(t.tokens)) {
        const MediaItem item = m_media->byId(mid);
        if (item.id == 0) {
            // Stale reference — silently skip. The token rewriter leaves
            // the original mediaId in place; the importer will null it
            // out on miss (matches §10.4's best-effort posture).
            continue;
        }
        QString reason;
        auto bytes = readWholeFile(item.path, &reason);
        if (!bytes) {
            qWarning().noquote() << "exportTheme: skipping media id" << mid
                                 << "—" << reason;
            continue;
        }
        const QString hash = sha256Hex(*bytes);
        mediaIdToHash.insert(mid, hash);
        // Dedup: same image referenced twice ships once.
        if (!mediaBytes.contains(hash)) {
            mediaBytes.insert(hash, *bytes);
            QJsonObject mEntry;
            mEntry[QStringLiteral("hash")]            = hash;
            mEntry[QStringLiteral("originalFilename")] = QFileInfo(item.path).fileName();
            mEntry[QStringLiteral("bytes")]            = qint64(bytes->size());
            mEntry[QStringLiteral("originalMediaId")] = mid;
            mEntry[QStringLiteral("type")]             = item.type;
            mediaManifest.append(mEntry);
        }
    }

    // ── Resolve fonts (respecting the exclusion list) ───────────────────
    QSet<QString> excluded;
    for (const QString& f : excludedFontFamilies) excluded.insert(f);

    QHash<QString, QString>   fontFamilyToHash;  // for token rewrite
    QHash<QString, QByteArray> fontBytes;        // hash -> bytes
    QJsonArray fontManifest;

    if (m_fonts) {
        for (const QString& fam : collectFontFamilies(t.tokens)) {
            if (excluded.contains(fam)) continue;
            const QString src = m_fonts->filePathForFamily(fam);
            if (src.isEmpty()) continue;   // system-only; not bundleable
            QString reason;
            auto bytes = readWholeFile(src, &reason);
            if (!bytes) {
                qWarning().noquote() << "exportTheme: skipping font" << fam
                                     << "—" << reason;
                continue;
            }
            const QString hash = sha256Hex(*bytes);
            fontFamilyToHash.insert(fam, hash);
            if (!fontBytes.contains(hash)) {
                fontBytes.insert(hash, *bytes);
                QJsonObject fEntry;
                fEntry[QStringLiteral("hash")]   = hash;
                fEntry[QStringLiteral("family")] = fam;
                fEntry[QStringLiteral("bytes")]  = qint64(bytes->size());
                fontManifest.append(fEntry);
            }
        }
    }

    // ── Build the rewritten theme.json + manifest.json ─────────────────
    const QVariantMap rewritten = rewriteTokensForExport(
        t.tokens, mediaIdToHash, fontFamilyToHash);

    const QByteArray themeJson = QJsonDocument(
        QJsonObject::fromVariantMap(rewritten)).toJson(QJsonDocument::Indented);

    QJsonObject manifest;
    manifest[QStringLiteral("kind")]          = QStringLiteral("craterheme");
    manifest[QStringLiteral("formatVersion")] = kBundleFormatVersion;
    manifest[QStringLiteral("themeKind")]     = t.kind;
    manifest[QStringLiteral("name")]          = t.name;
    manifest[QStringLiteral("exportedAt")]    = QDateTime::currentMSecsSinceEpoch();
    manifest[QStringLiteral("appVersion")]    = versionString();
    manifest[QStringLiteral("media")]         = mediaManifest;
    manifest[QStringLiteral("fonts")]         = fontManifest;
    const QByteArray manifestJson =
        QJsonDocument(manifest).toJson(QJsonDocument::Indented);

    // ── Write zip (atomic via QSaveFile inside ZipWriter) ───────────────
    bundle::ZipWriter zip(filePath);
    if (!zip.isOpen()) {
        m_lastExportError = zip.errorString();
        return false;
    }
    const auto fail = [&](QString why) {
        m_lastExportError = std::move(why);
        return false;
    };
    if (!zip.addEntry(QStringLiteral("manifest.json"), manifestJson))
        return fail(zip.errorString());
    if (!zip.addEntry(QStringLiteral("theme.json"), themeJson))
        return fail(zip.errorString());

    for (auto it = mediaBytes.constBegin(); it != mediaBytes.constEnd(); ++it) {
        const QString hash = it.key();
        // Look up the manifest entry to recover the original extension.
        QString ext;
        for (const QJsonValue& v : mediaManifest) {
            const QJsonObject o = v.toObject();
            if (o.value(QStringLiteral("hash")).toString() == hash) {
                ext = QFileInfo(o.value(QStringLiteral("originalFilename"))
                                   .toString()).suffix();
                break;
            }
        }
        const QString name = ext.isEmpty()
            ? QStringLiteral("media/%1").arg(hash)
            : QStringLiteral("media/%1.%2").arg(hash, ext.toLower());
        if (!zip.addEntry(name, it.value()))
            return fail(zip.errorString());
    }
    for (auto it = fontBytes.constBegin(); it != fontBytes.constEnd(); ++it) {
        // We always wrote .ttf or .otf into AppData/fonts; reuse that
        // extension. (FontService sniffed the magic bytes at import time.)
        QString ext;
        for (const QJsonValue& v : fontManifest) {
            const QJsonObject o = v.toObject();
            if (o.value(QStringLiteral("hash")).toString() == it.key()) {
                const QString fam = o.value(QStringLiteral("family")).toString();
                const QString path = m_fonts ? m_fonts->filePathForFamily(fam) : QString();
                ext = QFileInfo(path).suffix();
                break;
            }
        }
        const QString name = ext.isEmpty()
            ? QStringLiteral("fonts/%1").arg(it.key())
            : QStringLiteral("fonts/%1.%2").arg(it.key(), ext.toLower());
        if (!zip.addEntry(name, it.value()))
            return fail(zip.errorString());
    }

    if (!zip.commit())
        return fail(zip.errorString());

    qInfo().noquote() << "ThemeService: exported theme" << t.id << "("
                      << t.name << ") to" << filePath
                      << "— bundled" << mediaManifest.size() << "media,"
                      << fontManifest.size() << "fonts";
    return true;
}

ThemeImportReport ThemeService::importThemeFile(QString filePath)
{
    ThemeImportReport report;
    m_lastImportError.clear();
    if (!m_impl) {
        report.errorMessage = QStringLiteral("Theme service not available");
        m_lastImportError = report.errorMessage;
        return report;
    }

    // Reject v1 (JSON) outright — per ARCHITECTURE.md §10.2 the format
    // break is deliberate. Sniff the leading bytes: v2 = PK\x03\x04, v1
    // would start with '{' or whitespace. We don't want a maintenance-
    // forever parser fork; the error tells the user how to recover.
    QFile probe(filePath);
    if (!probe.open(QIODevice::ReadOnly)) {
        report.errorMessage = QStringLiteral("Cannot open %1: %2")
                                  .arg(filePath, probe.errorString());
        m_lastImportError = report.errorMessage;
        return report;
    }
    const QByteArray head = probe.read(4);
    probe.close();
    if (head.size() < 4 || head[0] != 'P' || head[1] != 'K'
        || (uint8_t(head[2]) != 0x03) || (uint8_t(head[3]) != 0x04)) {
        report.errorMessage = QStringLiteral(
            "This file was exported by an older version of Crater. "
            "Please re-export from the original installation.");
        m_lastImportError = report.errorMessage;
        return report;
    }

    bundle::ZipReader zip(filePath);
    if (!zip.isOpen()) {
        report.errorMessage = zip.errorString();
        m_lastImportError = report.errorMessage;
        return report;
    }

    // ── Validate manifest ───────────────────────────────────────────────
    const QByteArray manifestBytes = zip.readEntry(QStringLiteral("manifest.json"));
    if (manifestBytes.isEmpty()) {
        report.errorMessage = QStringLiteral("Bundle is missing manifest.json");
        m_lastImportError = report.errorMessage;
        return report;
    }
    QJsonParseError pe{};
    const QJsonDocument manifestDoc = QJsonDocument::fromJson(manifestBytes, &pe);
    if (pe.error != QJsonParseError::NoError || !manifestDoc.isObject()) {
        report.errorMessage = QStringLiteral("manifest.json is not valid JSON: %1")
                                  .arg(pe.errorString());
        m_lastImportError = report.errorMessage;
        return report;
    }
    const QJsonObject manifest = manifestDoc.object();
    if (manifest.value(QStringLiteral("kind")).toString() != QLatin1String("craterheme")) {
        report.errorMessage = QStringLiteral("manifest.json missing craterheme magic header");
        m_lastImportError = report.errorMessage;
        return report;
    }
    if (manifest.value(QStringLiteral("formatVersion")).toInt() != kBundleFormatVersion) {
        report.errorMessage = QStringLiteral(
            "Unsupported formatVersion %1; expected %2")
            .arg(manifest.value(QStringLiteral("formatVersion")).toInt())
            .arg(kBundleFormatVersion);
        m_lastImportError = report.errorMessage;
        return report;
    }
    static const QSet<QString> validKinds{ "song", "scripture", "presentation" };
    const QString kind = manifest.value(QStringLiteral("themeKind")).toString();
    if (!validKinds.contains(kind)) {
        report.errorMessage = QStringLiteral("Unknown themeKind '%1'").arg(kind);
        m_lastImportError = report.errorMessage;
        return report;
    }

    // ── Read theme.json (the rewritten tokens body) ─────────────────────
    const QByteArray themeBytes = zip.readEntry(QStringLiteral("theme.json"));
    if (themeBytes.isEmpty()) {
        report.errorMessage = QStringLiteral("Bundle is missing theme.json");
        m_lastImportError = report.errorMessage;
        return report;
    }
    const QJsonDocument themeDoc = QJsonDocument::fromJson(themeBytes, &pe);
    if (pe.error != QJsonParseError::NoError || !themeDoc.isObject()) {
        report.errorMessage = QStringLiteral("theme.json is not valid JSON: %1")
                                  .arg(pe.errorString());
        m_lastImportError = report.errorMessage;
        return report;
    }
    QVariantMap onDiskTokens = themeDoc.object().toVariantMap();

    // ── Best-effort media import ────────────────────────────────────────
    // Track every on-disk file we create so a later catastrophic failure
    // (theme INSERT itself) can roll the filesystem back. SQLite gives us
    // atomicity for free; the filesystem does not (ARCHITECTURE.md §10.4).
    QStringList createdFiles;
    const auto rollbackFiles = [&]() {
        for (const QString& p : createdFiles) QFile::remove(p);
    };

    QHash<QString, qint64> hashToMediaId;
    const QJsonArray mediaArr = manifest.value(QStringLiteral("media")).toArray();
    for (const QJsonValue& v : mediaArr) {
        const QJsonObject e = v.toObject();
        const QString hash = e.value(QStringLiteral("hash")).toString();
        const QString origName = e.value(QStringLiteral("originalFilename")).toString();
        const qint64  expected = e.value(QStringLiteral("bytes")).toVariant().toLongLong();
        if (hash.isEmpty()) continue;

        // Locate the entry in the zip — we don't know the extension a
        // priori, so probe the names. Bundle filenames are
        // "media/<hash>.<ext>" or just "media/<hash>" — accept either.
        QString entryName;
        for (const QString& candidate : zip.entryNames()) {
            if (candidate.startsWith(QStringLiteral("media/") + hash)) {
                entryName = candidate;
                break;
            }
        }
        if (entryName.isEmpty()) {
            report.mediaWarnings.append(QStringLiteral(
                "missing media entry for '%1' (hash %2…)").arg(origName, hash.left(8)));
            continue;
        }
        const QByteArray bytes = zip.readEntry(entryName);
        if (bytes.isEmpty()) {
            report.mediaWarnings.append(QStringLiteral(
                "could not read or CRC failed for '%1'").arg(origName));
            continue;
        }
        if (bytes.size() != expected) {
            report.mediaWarnings.append(QStringLiteral(
                "size mismatch for '%1': bundle says %2, got %3")
                .arg(origName).arg(expected).arg(bytes.size()));
            continue;
        }
        if (sha256Hex(bytes) != hash) {
            report.mediaWarnings.append(QStringLiteral(
                "hash mismatch for '%1' (possibly tampered)").arg(origName));
            continue;
        }

        // Extract to a staging file, then route through MediaService so
        // §5.1 boundary validation (magic bytes, size cap, path
        // confinement) runs on the same path it does for normal imports.
        const QString stagingDir =
            QDir(db::DbPaths::importStagingDir())
                .filePath(QUuid::createUuid().toString(QUuid::WithoutBraces));
        QDir().mkpath(stagingDir);
        const QString stagingPath = QDir(stagingDir).filePath(
            origName.isEmpty() ? hash : origName);
        QFile out(stagingPath);
        if (!out.open(QIODevice::WriteOnly)) {
            report.mediaWarnings.append(QStringLiteral(
                "cannot stage '%1': %2").arg(origName, out.errorString()));
            continue;
        }
        out.write(bytes);
        out.close();

        if (!m_media) {
            report.mediaWarnings.append(QStringLiteral(
                "MediaService not wired — skipped '%1'").arg(origName));
            QFile::remove(stagingPath);
            QDir(stagingDir).removeRecursively();
            continue;
        }
        const qint64 newId = m_media->importPathSync(stagingPath);
        QFile::remove(stagingPath);
        QDir(stagingDir).removeRecursively();
        if (newId == 0) {
            report.mediaWarnings.append(QStringLiteral(
                "MediaService refused '%1': %2")
                .arg(origName, m_media->lastImportError()));
            continue;
        }
        hashToMediaId.insert(hash, newId);
        // The new media file lives at <mediaDir>/<filename>; MediaService
        // owns its layout, but the absolute path is recoverable via
        // byId(newId).path. Track it for potential rollback.
        const MediaItem mi = m_media->byId(newId);
        if (!mi.path.isEmpty()) createdFiles.append(mi.path);
    }

    // ── Best-effort font import ─────────────────────────────────────────
    const QJsonArray fontArr = manifest.value(QStringLiteral("fonts")).toArray();
    for (const QJsonValue& v : fontArr) {
        const QJsonObject e = v.toObject();
        const QString hash   = e.value(QStringLiteral("hash")).toString();
        const QString family = e.value(QStringLiteral("family")).toString();
        const qint64  expected = e.value(QStringLiteral("bytes")).toVariant().toLongLong();
        if (hash.isEmpty()) continue;

        QString entryName;
        for (const QString& candidate : zip.entryNames()) {
            if (candidate.startsWith(QStringLiteral("fonts/") + hash)) {
                entryName = candidate;
                break;
            }
        }
        if (entryName.isEmpty()) {
            report.fontWarnings.append(QStringLiteral(
                "missing font entry for '%1' (hash %2…)").arg(family, hash.left(8)));
            continue;
        }
        const QByteArray bytes = zip.readEntry(entryName);
        if (bytes.isEmpty() || bytes.size() != expected || sha256Hex(bytes) != hash) {
            report.fontWarnings.append(QStringLiteral(
                "integrity check failed for '%1'").arg(family));
            continue;
        }

        if (!m_fonts) {
            report.fontWarnings.append(QStringLiteral(
                "FontService not wired — skipped '%1'").arg(family));
            continue;
        }

        // FontService.importFontFile wants a path, so stage to disk first.
        const QString stagingDir =
            QDir(db::DbPaths::importStagingDir())
                .filePath(QUuid::createUuid().toString(QUuid::WithoutBraces));
        QDir().mkpath(stagingDir);
        const QString stagingPath = QDir(stagingDir).filePath(hash);
        QFile out(stagingPath);
        if (!out.open(QIODevice::WriteOnly)) {
            report.fontWarnings.append(QStringLiteral(
                "cannot stage font '%1': %2").arg(family, out.errorString()));
            continue;
        }
        out.write(bytes);
        out.close();

        const UserFont uf = m_fonts->importFontFile(stagingPath);
        QFile::remove(stagingPath);
        QDir(stagingDir).removeRecursively();
        if (uf.id == 0) {
            report.fontWarnings.append(QStringLiteral(
                "FontService refused '%1': %2")
                .arg(family, m_fonts->lastError()));
            continue;
        }
        if (!uf.path.isEmpty()) createdFiles.append(uf.path);
    }

    // ── Rewrite tokens with resolved media ids ──────────────────────────
    const QVariantMap runtimeTokens =
        rewriteTokensForImport(onDiskTokens, hashToMediaId);

    // Validate rewritten tokens. A failure here IS catastrophic — the
    // bundle's token shape is corrupt independently of media availability,
    // and creating the theme row with broken tokens would yield an
    // unusable artifact that the editor would later refuse to save.
    const QStringList errs = validateTokensV2(runtimeTokens);
    if (!errs.isEmpty()) {
        report.errorMessage = QStringLiteral("theme.json schema errors: %1")
                                  .arg(errs.join(QStringLiteral("; ")));
        m_lastImportError = report.errorMessage;
        rollbackFiles();
        return report;
    }

    // ── Resolve a unique name and INSERT ────────────────────────────────
    QString name = manifest.value(QStringLiteral("name")).toString().trimmed();
    if (name.isEmpty()) name = QStringLiteral("Imported Theme");
    try {
        name = resolveImportName(m_impl->countByKindName, kind, name);
    } catch (const db::Error& e) {
        report.errorMessage = QStringLiteral("DB lookup failed: %1").arg(e.message());
        m_lastImportError = report.errorMessage;
        rollbackFiles();
        return report;
    }

    const qint64 newId = create(kind, name, runtimeTokens);
    if (newId == 0) {
        report.errorMessage = QStringLiteral("theme INSERT failed");
        m_lastImportError = report.errorMessage;
        rollbackFiles();
        return report;
    }

    report.themeId = newId;
    qInfo().noquote() << "ThemeService: imported theme" << newId << "(" << name
                      << ") — media warnings:" << report.mediaWarnings.size()
                      << "font warnings:" << report.fontWarnings.size();
    return report;
}

void ThemeService::sweepImportStaging()
{
    // The bundle import path (importThemeFile) creates per-import temp
    // directories under AppDataLocation/.import-staging/<uuid>/ and
    // cleans them up on success/failure. A process kill mid-import would
    // leak the directory. Sweep at startup so the leak is bounded to one
    // run. Idempotent — safe to call when the directory doesn't exist.
    QDir staging(db::DbPaths::importStagingDir());
    if (!staging.exists()) return;
    const auto entries = staging.entryList(
        QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot | QDir::Hidden);
    int swept = 0;
    for (const QString& name : entries) {
        QDir(staging.filePath(name)).removeRecursively();
        ++swept;
    }
    if (swept > 0) {
        qInfo().noquote() << "ThemeService::sweepImportStaging: removed"
                          << swept << "leftover staging entries";
    }
}

qint64 ThemeService::duplicateTheme(qint64 id, QString newName)
{
    if (!m_impl) return 0;
    const Theme src = theme(id);
    if (src.id == 0) return 0;
    const QString name = newName.isEmpty()
        ? QStringLiteral("%1 (Copy)").arg(src.name)
        : newName;
    return create(src.kind, name, src.tokens);
}

}  // namespace crater
