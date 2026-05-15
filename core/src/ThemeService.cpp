#include "crater/ThemeService.h"

#include "crater/Version.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QColor>
#include <QDateTime>
#include <QDebug>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSet>

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
    textData["autoResize"]  = false;
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
// editor can surface them inline. Called from importFromJson, create, and
// update — but never during preview rendering, which must tolerate partial
// in-progress state.

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
        if (isB.step() && isB.columnInt(0) != 0) {
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

QString ThemeService::serializeForExport(qint64 id)
{
    const Theme t = theme(id);
    if (t.id == 0) return {};

    QVariantMap wrapper;
    wrapper["kind"]          = QStringLiteral("craterheme");
    wrapper["formatVersion"] = 1;
    wrapper["themeKind"]     = t.kind;
    wrapper["name"]          = t.name;
    wrapper["author"]        = QString();
    wrapper["exportedAt"]    = QDateTime::currentMSecsSinceEpoch();
    wrapper["appVersion"]    = versionString();
    wrapper["tokens"]        = t.tokens;

    return QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(wrapper)).toJson(QJsonDocument::Indented));
}

bool ThemeService::exportTheme(qint64 id, QString filePath)
{
    const QString json = serializeForExport(id);
    if (json.isEmpty()) return false;

    // QSaveFile = tmpfile + atomic rename + fsync. Per ARCHITECTURE.md §8.
    QSaveFile f(filePath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning().noquote() << "ThemeService::exportTheme(): cannot open" << filePath
                             << "—" << f.errorString();
        return false;
    }
    f.write(json.toUtf8());
    if (!f.commit()) {
        qWarning().noquote() << "ThemeService::exportTheme(): commit failed —" << f.errorString();
        return false;
    }
    return true;
}

namespace {

// Builds a unique theme name within (kind, name) by appending " (Import)",
// " (Import 2)", … until no row matches. Used by importFromJson.
QString resolveImportName(db::Statement& countStmt, const QString& kind, const QString& base)
{
    const auto exists = [&](const QString& n) -> bool {
        countStmt.reset();
        countStmt.bind(1, kind);
        countStmt.bind(2, n);
        return countStmt.step() && countStmt.columnInt(0) > 0;
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

}  // namespace

qint64 ThemeService::importFromJson(QString jsonText)
{
    m_lastImportError.clear();
    if (!m_impl) {
        m_lastImportError = QStringLiteral("Theme service not available");
        return 0;
    }

    QJsonParseError pe{};
    const auto doc = QJsonDocument::fromJson(jsonText.toUtf8(), &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject()) {
        m_lastImportError = QStringLiteral("Not a valid JSON document: %1").arg(pe.errorString());
        return 0;
    }
    const QVariantMap wrapper = doc.object().toVariantMap();

    if (wrapper.value("kind").toString() != QLatin1String("craterheme")) {
        m_lastImportError = QStringLiteral("File is not a Crater theme (missing magic header)");
        return 0;
    }
    if (wrapper.value("formatVersion").toInt() != 1) {
        m_lastImportError = QStringLiteral("Unsupported formatVersion %1; expected 1")
                                .arg(wrapper.value("formatVersion").toInt());
        return 0;
    }
    static const QSet<QString> validKinds{ "song", "scripture", "presentation" };
    const QString kind = wrapper.value("themeKind").toString();
    if (!validKinds.contains(kind)) {
        m_lastImportError = QStringLiteral("Unknown themeKind '%1'").arg(kind);
        return 0;
    }

    const QVariantMap tokens = wrapper.value("tokens").toMap();
    const QStringList errs = validateTokensV2(tokens);
    if (!errs.isEmpty()) {
        m_lastImportError = QStringLiteral("Schema errors: %1").arg(errs.join(QStringLiteral("; ")));
        return 0;
    }

    QString name = wrapper.value("name").toString().trimmed();
    if (name.isEmpty()) name = QStringLiteral("Imported Theme");
    try {
        name = resolveImportName(m_impl->countByKindName, kind, name);
    } catch (const db::Error& e) {
        m_lastImportError = QStringLiteral("DB lookup failed: %1").arg(e.message());
        return 0;
    }

    return create(kind, name, tokens);
}

qint64 ThemeService::importThemeFile(QString filePath)
{
    m_lastImportError.clear();
    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        m_lastImportError = QStringLiteral("Cannot open %1: %2").arg(filePath, f.errorString());
        return 0;
    }
    const QString json = QString::fromUtf8(f.readAll());
    return importFromJson(json);
}

QString ThemeService::lastImportError() const
{
    return m_lastImportError;
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
