#include "crater/WorkingTheme.h"

#include <QRandomGenerator>
#include <QSet>

#include <algorithm>
#include <climits>

namespace crater {

namespace {

// Defaults for new nodes. Visually sensible starting positions so a user can
// drop a Text or Container, see it on the canvas, and start tweaking — not
// invisible at 0/0/0/0.

QVariantMap defaultStyleForText()
{
    QVariantMap s;
    s["x"]                    = 20;
    s["y"]                    = 40;
    s["width"]                = 60;
    s["height"]               = 20;
    s["z"]                    = 10;
    s["opacity"]              = 1;
    s["color"]                = QStringLiteral("#ffffff");
    s["fontFamily"]           = QStringLiteral("Segoe UI Variable Display");
    s["fontPixelSize"]        = 56;
    s["fontWeight"]           = 500;
    s["lineHeightMultiplier"] = 1.25;
    s["letterSpacing"]        = 0.0;
    s["textAlign"]            = QStringLiteral("center");
    s["verticalAlign"]        = QStringLiteral("center");
    s["skewX"]                = 0;
    s["skewY"]                = 0;
    return s;
}

QVariantMap defaultDataForText()
{
    QVariantMap d;
    d["layerName"]   = QStringLiteral("Text");
    d["linkage"]     = QStringLiteral("custom");
    d["text"]        = QStringLiteral("New text");
    d["autoResize"]  = true;
    d["maxFontSize"] = 220;
    return d;
}

QVariantMap defaultStyleForContainer()
{
    QVariantMap s;
    s["x"]               = 10;
    s["y"]               = 10;
    s["width"]           = 30;
    s["height"]          = 30;
    s["z"]               = 5;
    s["opacity"]         = 1;
    s["backgroundColor"] = QStringLiteral("#1f1f24");
    s["skewX"]           = 0;
    s["skewY"]           = 0;
    return s;
}

QVariantMap defaultDataForContainer()
{
    QVariantMap d;
    d["layerName"]    = QStringLiteral("Container");
    d["mediaId"]      = QVariant::fromValue(nullptr);
    d["bgOpacity"]    = 1;
    d["overlayColor"] = QVariant::fromValue(nullptr);
    return d;
}

}  // namespace

WorkingTheme::WorkingTheme(QObject* parent)
    : QObject(parent)
{
    // Initial blank state — 1920x1080 canvas, no nodes. loadFrom() overrides.
    m_canvas.insert("width",  1920);
    m_canvas.insert("height", 1080);
}

void WorkingTheme::loadFrom(QVariantMap tokens)
{
    const QVariantMap newCanvas = tokens.value("canvas").toMap();
    QVariantMap effectiveCanvas;
    effectiveCanvas["width"]  = newCanvas.value("width",  1920);
    effectiveCanvas["height"] = newCanvas.value("height", 1080);

    m_canvas = effectiveCanvas;
    m_nodes  = tokens.value("nodes").toList();

    emit canvasChanged();
    emit nodesChanged();
}

QVariantMap WorkingTheme::toTokens() const
{
    QVariantMap t;
    t["version"] = 2;
    t["canvas"]  = m_canvas;
    t["nodes"]   = m_nodes;
    return t;
}

QVariantMap WorkingTheme::node(QString id) const
{
    for (const QVariant& v : m_nodes) {
        const QVariantMap n = v.toMap();
        if (n.value("id").toString() == id) return n;
    }
    return {};
}

int WorkingTheme::indexOf(QString id) const
{
    for (int i = 0; i < m_nodes.size(); ++i) {
        if (m_nodes[i].toMap().value("id").toString() == id) return i;
    }
    return -1;
}

void WorkingTheme::setCanvas(int width, int height)
{
    if (width <= 0 || height <= 0) return;
    QVariantMap newCanvas;
    newCanvas["width"]  = width;
    newCanvas["height"] = height;
    if (newCanvas == m_canvas) return;
    m_canvas = newCanvas;
    emit canvasChanged();
}

void WorkingTheme::setNodeStyle(QString id, QString field, QVariant value)
{
    const int i = indexOf(id);
    if (i < 0) return;
    QVariantMap n     = m_nodes[i].toMap();
    QVariantMap style = n.value("style").toMap();
    if (style.value(field) == value) return;       // no-op, avoid signal spam
    style.insert(field, value);
    n.insert("style", style);
    m_nodes[i] = n;
    emit nodeStyleChanged(id, field);
    // z changes affect render order — consumers that sort by z (canvas
    // Repeater, ProjectionWindow Repeater) listen on nodesChanged to
    // re-sort. Fire it alongside the per-field signal.
    if (field == QLatin1String("z")) emit nodesChanged();
}

void WorkingTheme::setNodeData(QString id, QString field, QVariant value)
{
    const int i = indexOf(id);
    if (i < 0) return;
    QVariantMap n    = m_nodes[i].toMap();
    QVariantMap data = n.value("data").toMap();
    if (data.value(field) == value) return;
    data.insert(field, value);
    n.insert("data", data);
    m_nodes[i] = n;
    emit nodeDataChanged(id, field);
}

void WorkingTheme::renameNode(QString id, QString layerName)
{
    setNodeData(id, QStringLiteral("layerName"), layerName);
}

QString WorkingTheme::makeUniqueId(const QString& kindPrefix) const
{
    QSet<QString> taken;
    for (const QVariant& v : m_nodes) taken.insert(v.toMap().value("id").toString());
    // Short hex suffix from QRandomGenerator. Collision check is cheap (<50
    // nodes), so we just retry on the (vanishingly rare) hit.
    auto* rng = QRandomGenerator::global();
    for (int attempt = 0; attempt < 32; ++attempt) {
        const QString candidate = QStringLiteral("%1_%2")
            .arg(kindPrefix)
            .arg(rng->generate(), 6, 16, QChar('0'));
        if (!taken.contains(candidate)) return candidate;
    }
    return QStringLiteral("%1_%2").arg(kindPrefix).arg(m_nodes.size());
}

QString WorkingTheme::addNode(QString kind)
{
    QVariantMap n;
    if (kind == QLatin1String("text")) {
        n["id"]    = makeUniqueId(QStringLiteral("text"));
        n["kind"]  = QStringLiteral("text");
        n["style"] = defaultStyleForText();
        n["data"]  = defaultDataForText();
    } else if (kind == QLatin1String("container")) {
        n["id"]    = makeUniqueId(QStringLiteral("ctn"));
        n["kind"]  = QStringLiteral("container");
        n["style"] = defaultStyleForContainer();
        n["data"]  = defaultDataForContainer();
    } else {
        return {};
    }
    m_nodes.append(n);
    emit nodesChanged();
    return n.value("id").toString();
}

void WorkingTheme::removeNode(QString id)
{
    const int i = indexOf(id);
    if (i < 0) return;
    m_nodes.removeAt(i);
    emit nodesChanged();
}

QString WorkingTheme::duplicateNode(QString id)
{
    const int i = indexOf(id);
    if (i < 0) return {};
    QVariantMap copy = m_nodes[i].toMap();
    const QString prefix = copy.value("kind").toString() == QLatin1String("text")
                         ? QStringLiteral("text") : QStringLiteral("ctn");
    copy["id"] = makeUniqueId(prefix);

    // Copy in place — identical position and size to the source. The previous
    // +2% x/y "offset to distinguish the copy" shifted full-bleed background
    // containers off their (0,0) origin, leaving a visible gap and clipping the
    // far edge. The duplicate is inserted directly above the original (i + 1)
    // and appears as its own row in the Layers panel, which is how the operator
    // tells them apart; they can nudge it afterwards if they want.

    // Append " Copy" to the layerName.
    QVariantMap data = copy.value("data").toMap();
    data["layerName"] = data.value("layerName", copy.value("kind").toString()).toString()
                      + QStringLiteral(" Copy");
    copy["data"] = data;

    m_nodes.insert(i + 1, copy);
    emit nodesChanged();
    return copy.value("id").toString();
}

void WorkingTheme::reorderZ(QString id, int direction)
{
    const int i = indexOf(id);
    if (i < 0 || direction == 0) return;

    int zMin = INT_MAX, zMax = INT_MIN;
    for (const QVariant& v : m_nodes) {
        const int z = v.toMap().value("style").toMap().value("z").toInt();
        zMin = std::min(zMin, z);
        zMax = std::max(zMax, z);
    }

    QVariantMap n     = m_nodes[i].toMap();
    QVariantMap style = n.value("style").toMap();
    const int curZ = style.value("z").toInt();

    int newZ = curZ;
    if (direction >= 100)       newZ = zMax + 1;          // bring to front
    else if (direction <= -100) newZ = zMin - 1;          // send to back
    else                        newZ = curZ + direction;  // nudge

    if (newZ == curZ) return;
    style["z"] = newZ;
    n["style"] = style;
    m_nodes[i] = n;
    emit nodeStyleChanged(id, QStringLiteral("z"));
    emit nodesChanged();   // canvas + projection re-sort by z
}

void WorkingTheme::reorderNodes(QStringList orderedIdsFrontToBack)
{
    if (orderedIdsFrontToBack.isEmpty()) return;

    // Front-most (top of the Layers list) gets the highest z. Dense,
    // collision-free integers so the canvas + projection z-sort reproduce the
    // panel order exactly. Any id not found is skipped; the panel passes the
    // full set so that doesn't happen in practice.
    const int n = orderedIdsFrontToBack.size();
    bool changed = false;
    for (int rank = 0; rank < n; ++rank) {
        const int i = indexOf(orderedIdsFrontToBack.at(rank));
        if (i < 0) continue;
        const int newZ = n - rank;             // rank 0 (front) -> highest z
        QVariantMap node  = m_nodes[i].toMap();
        QVariantMap style = node.value("style").toMap();
        if (style.value("z").toInt() == newZ) continue;
        style["z"]    = newZ;
        node["style"] = style;
        m_nodes[i]    = node;
        changed = true;
    }
    if (changed) emit nodesChanged();          // canvas + panel re-sort by z
}

}  // namespace crater
