#include "crater/ThemeTokens.h"

#include <QSet>
#include <utility>

namespace crater::tokens {

namespace {

// Linkage -> slot. Kept here rather than in each caller because the slide
// editor, the renderer and the validator must agree on what a node binds;
// three copies of this table is three chances to drift.
//
// The image slot is a CONTAINER linkage, not a text one. A container
// already paints media from `data.mediaId` (NodeRenderer mounts
// MediaBackgroundLoader for any non-zero id), so a picture placeholder is
// that same container saying "take the id from the slide, not from me".
// Nothing new had to be taught to the paint path.
QString slotForTextLinkage(const QString& linkage)
{
    if (linkage == QLatin1String("presentationTitle"))     return QStringLiteral("title");
    if (linkage == QLatin1String("presentationBody"))      return QStringLiteral("body");
    if (linkage == QLatin1String("presentationSubtitle"))  return QStringLiteral("subtitle");
    if (linkage == QLatin1String("presentationBodyRight")) return QStringLiteral("bodyRight");
    return {};
}

}  // namespace

QStringList standardLayoutIds()
{
    return {
        QString::fromLatin1(kLayoutTitle),
        QString::fromLatin1(kLayoutSection),
        QString::fromLatin1(kLayoutContent),
        QString::fromLatin1(kLayoutTwoColumn),
        QString::fromLatin1(kLayoutQuote),
        QString::fromLatin1(kLayoutPicture),
        QString::fromLatin1(kLayoutBlank),
    };
}

QString defaultLayoutName(const QString& layoutId)
{
    if (layoutId == QLatin1String(kLayoutTitle))     return QStringLiteral("Title slide");
    if (layoutId == QLatin1String(kLayoutSection))   return QStringLiteral("Section divider");
    if (layoutId == QLatin1String(kLayoutContent))   return QStringLiteral("Title + content");
    if (layoutId == QLatin1String(kLayoutTwoColumn)) return QStringLiteral("Two columns");
    if (layoutId == QLatin1String(kLayoutQuote))     return QStringLiteral("Quote");
    if (layoutId == QLatin1String(kLayoutPicture))   return QStringLiteral("Picture");
    if (layoutId == QLatin1String(kLayoutBlank))     return QStringLiteral("Blank");
    // A custom id authored in the visual editor. Showing the raw id beats
    // showing nothing; the editor lets the author set a real name anyway.
    return layoutId;
}

QVariantList layoutsOf(const QVariantMap& tokens)
{
    const QVariantList declared = tokens.value(QStringLiteral("layouts")).toList();
    if (!declared.isEmpty()) return declared;

    // v2 (or any map that predates layouts): one implicit default layout
    // wrapping the bare `nodes` array. Synthesising it here rather than
    // making callers branch on version is what lets the render surfaces
    // treat every theme identically, including one loaded from a row whose
    // tokens_version column has not been migrated yet.
    const QVariantList nodes = tokens.value(QStringLiteral("nodes")).toList();
    if (nodes.isEmpty()) return {};

    QVariantMap only;
    only.insert(QStringLiteral("id"),      QString::fromLatin1(kLayoutContent));
    only.insert(QStringLiteral("name"),    defaultLayoutName(QString::fromLatin1(kLayoutContent)));
    only.insert(QStringLiteral("default"), true);
    only.insert(QStringLiteral("nodes"),   nodes);
    return { only };
}

QVariantMap resolveLayout(const QVariantMap& tokens, const QString& layoutId)
{
    const QVariantList all = layoutsOf(tokens);
    if (all.isEmpty()) return {};

    if (!layoutId.isEmpty()) {
        for (const QVariant& v : all) {
            const QVariantMap l = v.toMap();
            if (l.value(QStringLiteral("id")).toString() == layoutId) return l;
        }
    }
    for (const QVariant& v : all) {
        const QVariantMap l = v.toMap();
        if (l.value(QStringLiteral("default")).toBool()) return l;
    }
    return all.first().toMap();
}

QVariantList layoutNodes(const QVariantMap& tokens,
                         const QString&     layoutId,
                         qint64             slideMediaId)
{
    QVariantList nodes =
        resolveLayout(tokens, layoutId).value(QStringLiteral("nodes")).toList();
    if (slideMediaId <= 0) return nodes;

    for (int i = 0; i < nodes.size(); ++i) {
        QVariantMap node = nodes[i].toMap();
        if (node.value(QStringLiteral("kind")).toString() != QLatin1String("container"))
            continue;
        QVariantMap data = node.value(QStringLiteral("data")).toMap();
        if (data.value(QStringLiteral("linkage")).toString()
            != QLatin1String("presentationImage"))
            continue;
        data[QStringLiteral("mediaId")] = slideMediaId;
        node[QStringLiteral("data")]    = data;
        nodes[i] = node;
    }
    return nodes;
}

int backgroundNodeIndex(const QVariantList& nodes)
{
    int    best  = -1;
    double bestZ = 0;
    for (int i = 0; i < nodes.size(); ++i) {
        const QVariantMap node = nodes[i].toMap();
        if (node.value(QStringLiteral("kind")).toString() != QLatin1String("container"))
            continue;
        const QVariantMap data = node.value(QStringLiteral("data")).toMap();
        if (data.value(QStringLiteral("linkage")).toString()
            == QLatin1String("presentationImage"))
            continue;
        const QVariantMap st = node.value(QStringLiteral("style")).toMap();
        const bool full = st.value(QStringLiteral("x")).toDouble()      <= 0.5
                       && st.value(QStringLiteral("y")).toDouble()      <= 0.5
                       && st.value(QStringLiteral("width")).toDouble()  >= 99.5
                       && st.value(QStringLiteral("height")).toDouble() >= 99.5;
        if (!full) continue;
        const double z = st.value(QStringLiteral("z")).toDouble();
        if (best < 0 || z < bestZ) { best = i; bestZ = z; }
    }
    return best;
}

namespace {

bool isPictureBox(const QVariantMap& node)
{
    return node.value(QStringLiteral("data")).toMap()
               .value(QStringLiteral("linkage")).toString()
           == QLatin1String("presentationImage");
}

QVariant dynamicFlag(const QVariantMap& node)
{
    return node.value(QStringLiteral("data")).toMap()
               .value(QStringLiteral("dynamicBackground"));
}

void setMedia(QVariantList& nodes, int i, qint64 mediaId)
{
    QVariantMap node = nodes[i].toMap();
    QVariantMap data = node.value(QStringLiteral("data")).toMap();
    data[QStringLiteral("mediaId")] = mediaId;
    node[QStringLiteral("data")]    = data;
    nodes[i] = node;
}

}  // namespace

QList<int> dynamicBackgroundIndices(const QVariantList& nodes)
{
    QList<int> marked;
    for (int i = 0; i < nodes.size(); ++i) {
        const QVariantMap node = nodes[i].toMap();
        if (node.value(QStringLiteral("kind")).toString() != QLatin1String("container")
            || isPictureBox(node))
            continue;
        const QVariant flag = dynamicFlag(node);
        if (flag.isValid() && flag.toBool()) marked << i;
    }
    if (!marked.isEmpty()) return marked;

    const int base = backgroundNodeIndex(nodes);
    if (base < 0) return {};
    const QVariant flag = dynamicFlag(nodes[base].toMap());
    if (flag.isValid() && !flag.toBool()) return {};
    return { base };
}

QVariantList applyBackground(QVariantList nodes, qint64 mediaId, bool force)
{
    if (mediaId <= 0) return nodes;

    const QList<int> dyn = dynamicBackgroundIndices(nodes);
    if (!dyn.isEmpty()) {
        for (int i : dyn) setMedia(nodes, i, mediaId);
        return nodes;
    }

    const int base = backgroundNodeIndex(nodes);
    if (base >= 0) {
        // The base opted out. Only an explicit save writes through it.
        if (force) setMedia(nodes, base, mediaId);
        return nodes;
    }

    // Nothing to paint into: slide a plain container in under everything.
    double minZ = 0;
    for (const QVariant& v : std::as_const(nodes)) {
        const double z = v.toMap().value(QStringLiteral("style")).toMap()
                              .value(QStringLiteral("z")).toDouble();
        minZ = qMin(minZ, z);
    }
    nodes.prepend(QVariantMap{
        { QStringLiteral("id"),    QStringLiteral("serviceBackground") },
        { QStringLiteral("kind"),  QStringLiteral("container") },
        { QStringLiteral("style"), QVariantMap{
              { QStringLiteral("x"), 0 }, { QStringLiteral("y"), 0 },
              { QStringLiteral("width"), 100 }, { QStringLiteral("height"), 100 },
              { QStringLiteral("z"), minZ - 1 } } },
        { QStringLiteral("data"),  QVariantMap{ { QStringLiteral("mediaId"), mediaId } } },
    });
    return nodes;
}

QVariantMap withBackground(QVariantMap tokens, qint64 mediaId)
{
    if (mediaId <= 0) return tokens;
    if (tokens.contains(QStringLiteral("layouts"))) {
        QVariantList layouts = tokens.value(QStringLiteral("layouts")).toList();
        for (QVariant& v : layouts) {
            QVariantMap l = v.toMap();
            l[QStringLiteral("nodes")] =
                applyBackground(l.value(QStringLiteral("nodes")).toList(), mediaId, true);
            v = l;
        }
        tokens[QStringLiteral("layouts")] = layouts;
    } else {
        tokens[QStringLiteral("nodes")] =
            applyBackground(tokens.value(QStringLiteral("nodes")).toList(), mediaId, true);
    }
    return tokens;
}

bool hasLayout(const QVariantMap& tokens, const QString& layoutId)
{
    if (layoutId.isEmpty()) return false;
    const QVariantList all = layoutsOf(tokens);
    for (const QVariant& v : all) {
        if (v.toMap().value(QStringLiteral("id")).toString() == layoutId) return true;
    }
    return false;
}

QVariantMap layoutSlots(const QVariantMap& layout)
{
    QVariantMap out{
        { QStringLiteral("title"),     false },
        { QStringLiteral("body"),      false },
        { QStringLiteral("subtitle"),  false },
        { QStringLiteral("bodyRight"), false },
        { QStringLiteral("image"),     false },
    };

    const QVariantList nodes = layout.value(QStringLiteral("nodes")).toList();
    for (const QVariant& v : nodes) {
        const QVariantMap n       = v.toMap();
        const QVariantMap data    = n.value(QStringLiteral("data")).toMap();
        const QString     kind    = n.value(QStringLiteral("kind")).toString();
        const QString     linkage = data.value(QStringLiteral("linkage")).toString();

        if (kind == QLatin1String("text")) {
            const QString slot = slotForTextLinkage(linkage);
            if (!slot.isEmpty()) out[slot] = true;
        } else if (kind == QLatin1String("container")) {
            if (linkage == QLatin1String("presentationImage"))
                out[QStringLiteral("image")] = true;
        }
    }
    return out;
}

QVariantMap layoutSlotsFor(const QVariantMap& tokens, const QString& layoutId)
{
    return layoutSlots(resolveLayout(tokens, layoutId));
}

QVariantMap upgradeToV3(const QVariantMap& tokens)
{
    // Idempotency guard, matching the one migrateRowsToV2 already carries:
    // a row can hold v3 JSON while its tokens_version column still reads 2
    // (an INSERT that predated the stamp, a hand-edited database), and
    // re-wrapping already-wrapped layouts would bury every design one level
    // deeper and lose them all.
    if (tokens.value(QStringLiteral("version")).toInt() >= 3
        || tokens.contains(QStringLiteral("layouts"))) {
        QVariantMap already = tokens;
        already[QStringLiteral("version")] = 3;
        return already;
    }

    QVariantMap out;
    out.insert(QStringLiteral("version"), 3);
    out.insert(QStringLiteral("canvas"),  tokens.value(QStringLiteral("canvas")));
    out.insert(QStringLiteral("layouts"), layoutsOf(tokens));
    return out;
}

}  // namespace crater::tokens
