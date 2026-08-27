#include "crater/ThemeTokens.h"

#include <QSet>

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
