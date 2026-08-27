#include "crater/WorkingTheme.h"

#include "crater/ThemeTokens.h"

#include <QMap>
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

// ── Node-list helpers ──────────────────────────────────────────────────
// Free functions rather than members because addLayout and duplicateLayout
// build node lists that are not yet installed anywhere, so they cannot go
// through the members that read the current layout.

int indexIn(const QVariantList& nodes, const QString& id)
{
    for (int i = 0; i < nodes.size(); ++i) {
        if (nodes[i].toMap().value("id").toString() == id) return i;
    }
    return -1;
}

QString uniqueIdIn(const QVariantList& nodes, const QString& kindPrefix)
{
    QSet<QString> taken;
    for (const QVariant& v : nodes) taken.insert(v.toMap().value("id").toString());
    // Short hex suffix from QRandomGenerator. Collision check is cheap (<50
    // nodes), so we just retry on the (vanishingly rare) hit.
    auto* rng = QRandomGenerator::global();
    for (int attempt = 0; attempt < 32; ++attempt) {
        const QString candidate = QStringLiteral("%1_%2")
            .arg(kindPrefix)
            .arg(rng->generate(), 6, 16, QChar('0'));
        if (!taken.contains(candidate)) return candidate;
    }
    return QStringLiteral("%1_%2").arg(kindPrefix).arg(nodes.size());
}

// True for a node that carries a SLIDE's content rather than the theme's
// own chrome: the text bound to a presentation field, or the container
// standing in for the slide's picture. These are what a new layout
// replaces; everything else is branding that should carry across.
bool isContentNode(const QVariantMap& n)
{
    const QVariantMap data    = n.value("data").toMap();
    const QString     kind    = n.value("kind").toString();
    const QString     linkage = data.value("linkage").toString();

    if (kind == QLatin1String("text"))
        return linkage.startsWith(QLatin1String("presentation"));
    if (kind == QLatin1String("container"))
        return linkage == QLatin1String("presentationImage");
    return false;
}

// ── Layout skeletons ───────────────────────────────────────────────────
// The content nodes a freshly-added standard layout starts with, as
// percentages of the canvas.
//
// This is intentionally coarser than the built-in themes that
// scripts/gen-presentation-themes.py generates. Those are finished designs;
// this is a starting point the author is expected to drag around, and
// duplicating the generator's exact geometry here would create a second
// source of truth for "what a title slide looks like" that nothing keeps
// in sync. What the two DO share is the layout id vocabulary, which is the
// part that has to agree.
struct SlotSpec
{
    const char* linkage;              // "presentationImage" = the picture container
    double x, y, w, h;                // percent of canvas
    int         fontPx;
    int         weight;
    const char* hAlign;               // left | center | right
    const char* vAlign;               // start | center | end
    int         z;
};

QList<SlotSpec> skeletonFor(const QString& layoutId)
{
    using namespace crater::tokens;

    if (layoutId == QLatin1String(kLayoutTitle)) {
        return {
            { "presentationTitle",    10, 33, 80, 20, 96, 700, "center", "center", 10 },
            { "presentationSubtitle", 15, 56, 70, 10, 40, 400, "center", "center", 10 },
        };
    }
    if (layoutId == QLatin1String(kLayoutSection)) {
        return {
            { "presentationTitle",    10, 41, 80, 18, 84, 700, "center", "center", 10 },
        };
    }
    if (layoutId == QLatin1String(kLayoutTwoColumn)) {
        return {
            { "presentationTitle",     8,  9, 84, 14, 60, 600, "left",  "center", 10 },
            { "presentationBody",      8, 27, 40, 62, 34, 400, "left",  "start",  10 },
            { "presentationBodyRight", 52, 27, 40, 62, 34, 400, "left",  "start",  10 },
        };
    }
    if (layoutId == QLatin1String(kLayoutQuote)) {
        // Body first and large: a quote slide IS its quote, and the title
        // reads as the attribution beneath it.
        return {
            { "presentationBody",     12, 25, 76, 45, 56, 400, "center", "center", 10 },
            { "presentationTitle",    12, 74, 76, 10, 28, 500, "center", "center", 10 },
        };
    }
    if (layoutId == QLatin1String(kLayoutPicture)) {
        return {
            { "presentationImage",    52,  0, 48, 100,  0,   0, "left",  "center",  1 },
            { "presentationTitle",     6, 20, 40,  16, 52, 600, "left",  "center", 10 },
            { "presentationBody",      6, 40, 40,  42, 30, 400, "left",  "start",  10 },
        };
    }
    if (layoutId == QLatin1String(kLayoutBlank)) {
        // Background only — the chrome carried over from the default layout
        // is the whole design.
        return {};
    }
    // kLayoutContent and every custom id: the ordinary heading-over-body
    // shape, which is the most useful thing a blank custom design can be.
    return {
        { "presentationTitle",         8,  9, 84, 14, 60, 600, "left", "center", 10 },
        { "presentationBody",          8, 27, 84, 62, 40, 400, "left", "start",  10 },
    };
}

// A readable layer name for a slot, so the Layers panel is legible before
// the author renames anything.
QString layerNameForLinkage(const QString& linkage)
{
    if (linkage == QLatin1String("presentationTitle"))     return QStringLiteral("Title");
    if (linkage == QLatin1String("presentationSubtitle"))  return QStringLiteral("Subtitle");
    if (linkage == QLatin1String("presentationBody"))      return QStringLiteral("Body");
    if (linkage == QLatin1String("presentationBodyRight")) return QStringLiteral("Right column");
    if (linkage == QLatin1String("presentationImage"))     return QStringLiteral("Picture");
    return QStringLiteral("Text");
}

// The style a new text node should inherit so it looks like it belongs to
// this theme: colour, font family, letter spacing, line height, shadow.
// Geometry and size are overridden by the skeleton, since those are what
// distinguishes one design from another.
//
// Without this a new design in a dark theme starts as the editor's default
// white-on-nothing at 56px, and the author rebuilds by hand the very
// styling the template was supposed to give them.
QVariantMap textStyleDonor(const QVariantList& donorNodes)
{
    QVariantMap fallback = defaultStyleForText();
    QVariantMap anyText;
    for (const QVariant& v : donorNodes) {
        const QVariantMap n = v.toMap();
        if (n.value("kind").toString() != QLatin1String("text")) continue;
        if (anyText.isEmpty()) anyText = n.value("style").toMap();
        if (isContentNode(n)) return n.value("style").toMap();   // best match
    }
    return anyText.isEmpty() ? fallback : anyText;
}

}  // namespace

WorkingTheme::WorkingTheme(QObject* parent)
    : QObject(parent)
{
    // Initial blank state — 1920x1080 canvas, one empty default layout so
    // addNode() works on a freshly constructed instance. loadFrom() replaces
    // all of it.
    m_canvas.insert("width",  1920);
    m_canvas.insert("height", 1080);

    QVariantMap only;
    only.insert("id",      QString::fromLatin1(tokens::kLayoutContent));
    only.insert("name",    tokens::defaultLayoutName(QString::fromLatin1(tokens::kLayoutContent)));
    only.insert("default", true);
    only.insert("nodes",   QVariantList{});
    m_layouts = { only };
    m_current = 0;
}

// ── Read-through accessors ─────────────────────────────────────────────

QVariantList WorkingTheme::nodes() const
{
    if (m_current < 0 || m_current >= m_layouts.size()) return {};
    return m_layouts.at(m_current).toMap().value("nodes").toList();
}

QString WorkingTheme::currentLayoutId() const
{
    if (m_current < 0 || m_current >= m_layouts.size()) return {};
    return m_layouts.at(m_current).toMap().value("id").toString();
}

void WorkingTheme::putNodes(const QVariantList& nodes)
{
    if (m_current < 0 || m_current >= m_layouts.size()) return;
    QVariantMap l = m_layouts.at(m_current).toMap();
    l["nodes"]        = nodes;
    m_layouts[m_current] = l;
}

// ── Load / save ────────────────────────────────────────────────────────

void WorkingTheme::loadFrom(QVariantMap tokens)
{
    // Remembered across the reload so an undo does not also yank the author
    // out of the design they were editing — see the header.
    //
    // Only from the SECOND load on. The constructor seeds a placeholder
    // layout whose id is "content", and most presentation themes define a
    // design by that name, so carrying the selection across the very first
    // load would open every theme on its Title + content design instead of
    // on the one it flags default.
    const QString prevId = m_loaded ? currentLayoutId() : QString();
    m_loaded = true;

    const QVariantMap newCanvas = tokens.value("canvas").toMap();
    QVariantMap effectiveCanvas;
    effectiveCanvas["width"]  = newCanvas.value("width",  1920);
    effectiveCanvas["height"] = newCanvas.value("height", 1080);
    m_canvas = effectiveCanvas;

    // layoutsOf() accepts v2 as well, so an un-migrated theme opens here as
    // one implicit default layout rather than as nothing at all.
    m_layouts = crater::tokens::layoutsOf(tokens);
    if (m_layouts.isEmpty()) {
        QVariantMap only;
        only.insert("id",      QString::fromLatin1(crater::tokens::kLayoutContent));
        only.insert("name",    crater::tokens::defaultLayoutName(
                                   QString::fromLatin1(crater::tokens::kLayoutContent)));
        only.insert("default", true);
        only.insert("nodes",   QVariantList{});
        m_layouts = { only };
    }
    normalizeDefault();

    int idx = prevId.isEmpty() ? -1 : indexOfLayout(prevId);
    if (idx < 0) {
        idx = 0;
        for (int i = 0; i < m_layouts.size(); ++i) {
            if (m_layouts[i].toMap().value("default").toBool()) { idx = i; break; }
        }
    }
    m_current = idx;

    emit canvasChanged();
    emit layoutsChanged();
    emit currentLayoutChanged();
    emit nodesChanged();
}

QVariantMap WorkingTheme::toTokens() const
{
    QVariantMap t;
    t["version"] = 3;
    t["canvas"]  = m_canvas;
    t["layouts"] = m_layouts;
    return t;
}

// ── Node access ────────────────────────────────────────────────────────

QVariantMap WorkingTheme::node(QString id) const
{
    const QVariantList ns = nodes();
    const int i = indexIn(ns, id);
    return i < 0 ? QVariantMap{} : ns.at(i).toMap();
}

int WorkingTheme::indexOf(QString id) const
{
    return indexIn(nodes(), id);
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
    QVariantList ns = nodes();
    const int i = indexIn(ns, id);
    if (i < 0) return;
    QVariantMap n     = ns[i].toMap();
    QVariantMap style = n.value("style").toMap();
    if (style.value(field) == value) return;       // no-op, avoid signal spam
    style.insert(field, value);
    n.insert("style", style);
    ns[i] = n;
    putNodes(ns);
    emit nodeStyleChanged(id, field);
    // z changes affect render order — consumers that sort by z (canvas
    // Repeater, ProjectionWindow Repeater) listen on nodesChanged to
    // re-sort. Fire it alongside the per-field signal.
    if (field == QLatin1String("z")) emit nodesChanged();
}

void WorkingTheme::setNodeData(QString id, QString field, QVariant value)
{
    QVariantList ns = nodes();
    const int i = indexIn(ns, id);
    if (i < 0) return;
    QVariantMap n    = ns[i].toMap();
    QVariantMap data = n.value("data").toMap();
    if (data.value(field) == value) return;
    data.insert(field, value);
    n.insert("data", data);
    ns[i] = n;
    putNodes(ns);
    emit nodeDataChanged(id, field);
}

void WorkingTheme::renameNode(QString id, QString layerName)
{
    setNodeData(id, QStringLiteral("layerName"), layerName);
}

QString WorkingTheme::makeUniqueId(const QString& kindPrefix) const
{
    return uniqueIdIn(nodes(), kindPrefix);
}

QString WorkingTheme::addNode(QString kind)
{
    QVariantList ns = nodes();
    QVariantMap n;
    if (kind == QLatin1String("text")) {
        n["id"]    = uniqueIdIn(ns, QStringLiteral("text"));
        n["kind"]  = QStringLiteral("text");
        n["style"] = defaultStyleForText();
        n["data"]  = defaultDataForText();
    } else if (kind == QLatin1String("container")) {
        n["id"]    = uniqueIdIn(ns, QStringLiteral("ctn"));
        n["kind"]  = QStringLiteral("container");
        n["style"] = defaultStyleForContainer();
        n["data"]  = defaultDataForContainer();
    } else {
        return {};
    }
    ns.append(n);
    putNodes(ns);
    emit nodesChanged();
    return n.value("id").toString();
}

void WorkingTheme::removeNode(QString id)
{
    QVariantList ns = nodes();
    const int i = indexIn(ns, id);
    if (i < 0) return;
    ns.removeAt(i);
    putNodes(ns);
    emit nodesChanged();
}

QString WorkingTheme::duplicateNode(QString id)
{
    QVariantList ns = nodes();
    const int i = indexIn(ns, id);
    if (i < 0) return {};
    QVariantMap copy = ns[i].toMap();
    const QString prefix = copy.value("kind").toString() == QLatin1String("text")
                         ? QStringLiteral("text") : QStringLiteral("ctn");
    copy["id"] = uniqueIdIn(ns, prefix);

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

    ns.insert(i + 1, copy);
    putNodes(ns);
    emit nodesChanged();
    return copy.value("id").toString();
}

void WorkingTheme::reorderZ(QString id, int direction)
{
    QVariantList ns = nodes();
    const int i = indexIn(ns, id);
    if (i < 0 || direction == 0) return;

    int zMin = INT_MAX, zMax = INT_MIN;
    for (const QVariant& v : ns) {
        const int z = v.toMap().value("style").toMap().value("z").toInt();
        zMin = std::min(zMin, z);
        zMax = std::max(zMax, z);
    }

    QVariantMap n     = ns[i].toMap();
    QVariantMap style = n.value("style").toMap();
    const int curZ = style.value("z").toInt();

    int newZ = curZ;
    if (direction >= 100)       newZ = zMax + 1;          // bring to front
    else if (direction <= -100) newZ = zMin - 1;          // send to back
    else                        newZ = curZ + direction;  // nudge

    if (newZ == curZ) return;
    style["z"] = newZ;
    n["style"] = style;
    ns[i] = n;
    putNodes(ns);
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
    QVariantList ns = nodes();
    const int n = orderedIdsFrontToBack.size();
    bool changed = false;
    for (int rank = 0; rank < n; ++rank) {
        const int i = indexIn(ns, orderedIdsFrontToBack.at(rank));
        if (i < 0) continue;
        const int newZ = n - rank;             // rank 0 (front) -> highest z
        QVariantMap node  = ns[i].toMap();
        QVariantMap style = node.value("style").toMap();
        if (style.value("z").toInt() == newZ) continue;
        style["z"]    = newZ;
        node["style"] = style;
        ns[i]         = node;
        changed = true;
    }
    if (changed) {
        putNodes(ns);
        emit nodesChanged();                   // canvas + panel re-sort by z
    }
}

// ── Layouts ────────────────────────────────────────────────────────────

QVariantMap WorkingTheme::layout(QString layoutId) const
{
    const int i = indexOfLayout(layoutId);
    return i < 0 ? QVariantMap{} : m_layouts.at(i).toMap();
}

int WorkingTheme::indexOfLayout(QString layoutId) const
{
    if (layoutId.isEmpty()) return -1;
    for (int i = 0; i < m_layouts.size(); ++i) {
        if (m_layouts[i].toMap().value("id").toString() == layoutId) return i;
    }
    return -1;
}

bool WorkingTheme::hasLayout(QString layoutId) const
{
    return indexOfLayout(layoutId) >= 0;
}

QStringList WorkingTheme::unusedStandardLayoutIds() const
{
    QStringList out;
    for (const QString& id : crater::tokens::standardLayoutIds()) {
        if (indexOfLayout(id) < 0) out << id;
    }
    return out;
}

QString WorkingTheme::makeUniqueLayoutId() const
{
    auto* rng = QRandomGenerator::global();
    for (int attempt = 0; attempt < 32; ++attempt) {
        const QString candidate =
            QStringLiteral("custom_%1").arg(rng->generate(), 6, 16, QChar('0'));
        if (indexOfLayout(candidate) < 0) return candidate;
    }
    return QStringLiteral("custom_%1").arg(m_layouts.size());
}

void WorkingTheme::normalizeDefault()
{
    if (m_layouts.isEmpty()) return;

    int chosen = -1;
    for (int i = 0; i < m_layouts.size(); ++i) {
        if (m_layouts[i].toMap().value("default").toBool()) { chosen = i; break; }
    }
    if (chosen < 0) chosen = 0;

    for (int i = 0; i < m_layouts.size(); ++i) {
        QVariantMap l = m_layouts[i].toMap();
        const bool want = (i == chosen);
        if (l.value("default").toBool() == want && l.contains("default")) continue;
        l["default"]  = want;
        m_layouts[i]  = l;
    }
}

void WorkingTheme::setCurrentLayout(QString layoutId)
{
    const int i = indexOfLayout(layoutId);
    if (i < 0 || i == m_current) return;
    m_current = i;
    emit currentLayoutChanged();
    emit nodesChanged();       // the canvas is now showing a different design
}

QString WorkingTheme::addLayout(QString layoutId, QString name)
{
    QString id = layoutId.trimmed();
    if (id.isEmpty()) id = makeUniqueLayoutId();
    else if (indexOfLayout(id) >= 0) return {};       // ids are unique per theme

    // Chrome comes from the DEFAULT layout, not the current one. The default
    // is the theme's canonical look; the design the author happens to have
    // open could be a half-finished experiment.
    QVariantList donorNodes;
    for (int i = 0; i < m_layouts.size(); ++i) {
        if (m_layouts[i].toMap().value("default").toBool()) {
            donorNodes = m_layouts[i].toMap().value("nodes").toList();
            break;
        }
    }
    if (donorNodes.isEmpty() && !m_layouts.isEmpty())
        donorNodes = m_layouts.first().toMap().value("nodes").toList();

    QVariantList  chrome;
    QSet<QString> replacedIds;
    for (const QVariant& v : donorNodes) {
        const QVariantMap n = v.toMap();
        if (isContentNode(n)) replacedIds.insert(n.value("id").toString());
        else                  chrome.append(n);
    }

    const QVariantMap donorStyle = textStyleDonor(donorNodes);

    // Build the content nodes this layout id implies.
    QVariantList out = chrome;
    QStringList  newTextIds;
    for (const SlotSpec& s : skeletonFor(id)) {
        const QString linkage = QString::fromLatin1(s.linkage);
        QVariantMap n;
        QVariantMap style;
        QVariantMap data;

        if (linkage == QLatin1String("presentationImage")) {
            n["id"]   = uniqueIdIn(out, QStringLiteral("pic"));
            n["kind"] = QStringLiteral("container");
            style = defaultStyleForContainer();
            style["backgroundColor"] = QStringLiteral("#14141a");
            data  = defaultDataForContainer();
            data["linkage"] = linkage;
        } else {
            n["id"]   = uniqueIdIn(out, QStringLiteral("text"));
            n["kind"] = QStringLiteral("text");
            style = donorStyle;                     // colour / family / spacing
            style["fontPixelSize"] = s.fontPx;
            style["fontWeight"]    = s.weight;
            style["textAlign"]     = QString::fromLatin1(s.hAlign);
            style["verticalAlign"] = QString::fromLatin1(s.vAlign);
            data  = defaultDataForText();
            data["linkage"] = linkage;
            newTextIds << n["id"].toString();
        }

        style["x"]      = s.x;
        style["y"]      = s.y;
        style["width"]  = s.w;
        style["height"] = s.h;
        style["z"]      = s.z;
        data["layerName"] = layerNameForLinkage(linkage);

        n["style"] = style;
        n["data"]  = data;
        out.append(n);
    }

    // A group container hugs the nodes it lists in data.group.members. Its
    // old members are gone, so a card carried over verbatim would collapse
    // to a sliver of padding. Re-point the ones that wrapped CONTENT at the
    // new content nodes — that is how a card-styled theme gives its new
    // design the same card — and drop a card left with nothing to wrap.
    // A group of purely decorative members is left exactly as it was.
    for (int i = out.size() - 1; i >= 0; --i) {
        QVariantMap n     = out[i].toMap();
        QVariantMap data  = n.value("data").toMap();
        if (!data.contains("group")) continue;
        QVariantMap group = data.value("group").toMap();

        const QStringList members = group.value("members").toStringList();
        bool wrappedContent = false;
        QStringList kept;
        for (const QString& m : members) {
            if (replacedIds.contains(m)) { wrappedContent = true; continue; }
            if (indexIn(out, m) >= 0)    kept << m;
        }
        if (!wrappedContent) continue;              // decoration, leave alone

        kept += newTextIds;
        if (kept.isEmpty()) { out.removeAt(i); continue; }

        group["members"] = kept;
        data["group"]    = group;
        n["data"]        = data;
        out[i]           = n;
    }

    // Validation refuses an empty node list, and rightly: a layout that
    // draws nothing is indistinguishable from a broken one. A theme with no
    // chrome to inherit (a brand-new blank design) gets a background so the
    // author has something to click.
    if (out.isEmpty()) {
        QVariantMap bg;
        bg["id"]    = QStringLiteral("bg");
        bg["kind"]  = QStringLiteral("container");
        QVariantMap style = defaultStyleForContainer();
        style["x"] = 0; style["y"] = 0;
        style["width"] = 100; style["height"] = 100; style["z"] = 0;
        style["backgroundColor"] = QStringLiteral("#0a0a0d");
        QVariantMap data = defaultDataForContainer();
        data["layerName"] = QStringLiteral("Background");
        bg["style"] = style;
        bg["data"]  = data;
        out.append(bg);
    }

    QVariantMap l;
    l["id"]      = id;
    l["name"]    = name.trimmed().isEmpty() ? crater::tokens::defaultLayoutName(id)
                                            : name.trimmed();
    l["default"] = false;
    l["nodes"]   = out;
    m_layouts.append(l);
    normalizeDefault();

    emit layoutsChanged();
    return id;
}

QString WorkingTheme::duplicateLayout(QString layoutId)
{
    const int i = indexOfLayout(layoutId);
    if (i < 0) return {};

    const QVariantMap src   = m_layouts.at(i).toMap();
    const QVariantList srcN = src.value("nodes").toList();

    // Re-mint node ids, keeping a map so group member lists can follow. Node
    // ids only have to be unique WITHIN a layout, so sharing them across two
    // designs would validate — but the moment either copy is edited, "which
    // txt_1a2b3c did the card mean" has two answers.
    QMap<QString, QString> idMap;
    QVariantList out;
    for (const QVariant& v : srcN) {
        QVariantMap n = v.toMap();
        const QString oldId  = n.value("id").toString();
        const QString prefix = n.value("kind").toString() == QLatin1String("text")
                             ? QStringLiteral("text") : QStringLiteral("ctn");
        const QString newId  = uniqueIdIn(out, prefix);
        idMap.insert(oldId, newId);
        n["id"] = newId;
        out.append(n);
    }
    for (int k = 0; k < out.size(); ++k) {
        QVariantMap n    = out[k].toMap();
        QVariantMap data = n.value("data").toMap();
        if (!data.contains("group")) continue;
        QVariantMap group = data.value("group").toMap();
        QStringList members;
        for (const QString& m : group.value("members").toStringList())
            members << idMap.value(m, m);
        group["members"] = members;
        data["group"]    = group;
        n["data"]        = data;
        out[k]           = n;
    }

    QVariantMap copy;
    copy["id"]      = makeUniqueLayoutId();
    copy["name"]    = src.value("name").toString() + QStringLiteral(" Copy");
    copy["default"] = false;                     // never steal the default
    copy["nodes"]   = out;

    m_layouts.insert(i + 1, copy);
    if (m_current > i) ++m_current;              // selection stays on the same design
    normalizeDefault();

    emit layoutsChanged();
    return copy.value("id").toString();
}

void WorkingTheme::removeLayout(QString layoutId)
{
    if (m_layouts.size() <= 1) return;           // a theme needs one design
    const int i = indexOfLayout(layoutId);
    if (i < 0) return;

    m_layouts.removeAt(i);
    normalizeDefault();                          // promotes a survivor if needed

    const bool wasCurrent = (i == m_current);
    if (m_current > i)      --m_current;
    m_current = std::clamp(m_current, 0, int(m_layouts.size()) - 1);

    emit layoutsChanged();
    if (wasCurrent) {
        emit currentLayoutChanged();
        emit nodesChanged();
    }
}

void WorkingTheme::renameLayout(QString layoutId, QString name)
{
    const int i = indexOfLayout(layoutId);
    if (i < 0) return;
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty()) return;               // nameless designs are unpickable
    QVariantMap l = m_layouts.at(i).toMap();
    if (l.value("name").toString() == trimmed) return;
    l["name"]    = trimmed;
    m_layouts[i] = l;
    emit layoutsChanged();
}

void WorkingTheme::setDefaultLayout(QString layoutId)
{
    const int i = indexOfLayout(layoutId);
    if (i < 0) return;
    if (m_layouts.at(i).toMap().value("default").toBool()) return;

    for (int k = 0; k < m_layouts.size(); ++k) {
        QVariantMap l = m_layouts[k].toMap();
        l["default"]  = (k == i);
        m_layouts[k]  = l;
    }
    emit layoutsChanged();
}

void WorkingTheme::moveLayout(QString layoutId, int delta)
{
    const int i = indexOfLayout(layoutId);
    if (i < 0 || delta == 0) return;
    const int j = std::clamp(i + delta, 0, int(m_layouts.size()) - 1);
    if (j == i) return;

    m_layouts.move(i, j);
    // Follow the selection through the move, whether it was the moved
    // layout or one the move stepped over.
    if (m_current == i)                            m_current = j;
    else if (i < m_current && m_current <= j)      --m_current;
    else if (j <= m_current && m_current < i)      ++m_current;

    emit layoutsChanged();
}

}  // namespace crater
