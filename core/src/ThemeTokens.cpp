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

namespace {

double num(const QVariantMap& m, const char* key, double fallback = 0)
{
    const QVariant v = m.value(QString::fromLatin1(key));
    bool ok = false;
    const double d = v.toDouble(&ok);
    return ok ? d : fallback;
}

bool isScriptureTextLinkage(const QString& linkage)
{
    return linkage == QLatin1String("scriptureRef") || linkage == QLatin1String("scriptureText");
}

// Every node id another node in the column points at through a layout
// rule: a card's members, and the source of autoHeight / autoPosition.
QStringList layoutRefs(const QVariantMap& data)
{
    QStringList out;
    for (const QVariant& m : data.value(QStringLiteral("group")).toMap()
                                 .value(QStringLiteral("members")).toList())
        out << m.toString();
    const QVariantMap ah = data.value(QStringLiteral("autoHeight")).toMap();
    for (const char* k : { "source", "from", "to" })
        if (ah.contains(QLatin1String(k))) out << ah.value(QLatin1String(k)).toString();
    const QVariantMap ap = data.value(QStringLiteral("autoPosition")).toMap();
    if (ap.contains(QStringLiteral("source"))) out << ap.value(QStringLiteral("source")).toString();
    return out;
}

}  // namespace

QVariantList deriveSplitNodes(const QVariantList& nodes)
{
    constexpr double kGutter = 6.0;
    const QString suffix = QStringLiteral("-right");

    // 1. The passage column: the scripture text...
    QSet<QString> column;
    for (const QVariant& v : nodes) {
        const QVariantMap n = v.toMap();
        if (n.value(QStringLiteral("kind")).toString() == QLatin1String("text")
            && isScriptureTextLinkage(n.value(QStringLiteral("data")).toMap()
                                           .value(QStringLiteral("linkage")).toString()))
            column.insert(n.value(QStringLiteral("id")).toString());
    }
    if (column.isEmpty()) return nodes;

    // ...plus whatever is tied to it by a layout rule, either way round: the
    // card it sits in and the card's other members, a bar hugging the card,
    // a label stacked on the verse. Repeated until nothing new joins.
    for (bool grew = true; grew;) {
        grew = false;
        for (const QVariant& v : nodes) {
            const QVariantMap n = v.toMap();
            const QString id = n.value(QStringLiteral("id")).toString();
            const QStringList refs = layoutRefs(n.value(QStringLiteral("data")).toMap());
            const bool inColumn = column.contains(id);
            bool touches = false;
            for (const QString& r : refs) touches = touches || column.contains(r);
            if (!inColumn && touches) { column.insert(id); grew = true; }
            if (inColumn && n.value(QStringLiteral("data")).toMap().contains(QStringLiteral("group"))) {
                for (const QString& r : refs)
                    if (!column.contains(r)) { column.insert(r); grew = true; }
            }
        }
    }

    // 2. Its horizontal extent, in percent of the canvas.
    double x0 = 100, x1 = 0;
    for (const QVariant& v : nodes) {
        const QVariantMap n = v.toMap();
        if (!column.contains(n.value(QStringLiteral("id")).toString())) continue;
        const QVariantMap st = n.value(QStringLiteral("style")).toMap();
        x0 = qMin(x0, num(st, "x"));
        x1 = qMax(x1, num(st, "x") + num(st, "width"));
    }

    // 3. Decorations inside the column (an accent rule under the reference)
    //    go with it. Full-width pieces are the background, drawn once.
    for (const QVariant& v : nodes) {
        const QVariantMap n = v.toMap();
        const QString id = n.value(QStringLiteral("id")).toString();
        if (column.contains(id)) continue;
        const QVariantMap st = n.value(QStringLiteral("style")).toMap();
        const double x = num(st, "x"), w = num(st, "width");
        if (w < 90 && x >= x0 - 0.5 && x + w <= x1 + 0.5) column.insert(id);
    }

    // 4. The two halves. The column keeps its left margin, mirrored on the
    //    right. A column that starts past the middle (an odd design) falls
    //    back to a 5% margin.
    if (x0 > 50 - kGutter / 2 - 10) x0 = 5;
    const double half  = 50 - kGutter / 2 - x0;
    const double width = qMax(1.0, x1 - x0);
    const double scale = half / width;
    const double rightStart = 50 + kGutter / 2;

    const auto renamed = [&](const QString& id) {
        return column.contains(id) ? id + suffix : id;
    };
    const auto place = [&](QVariantMap n, double start) {
        QVariantMap st = n.value(QStringLiteral("style")).toMap();
        st.insert(QStringLiteral("x"),     start + (num(st, "x") - x0) * scale);
        st.insert(QStringLiteral("width"), num(st, "width") * scale);
        n.insert(QStringLiteral("style"), st);
        return n;
    };

    // A thin line down the middle of the gutter, for a design whose passage
    // sits straight on the background. A design with a card has none: the
    // two cards already read as two. Same colour as the verse text at about
    // a quarter strength, as tall as the passage column.
    QVariantMap divider;
    {
        bool hasCard = false;
        double top = 100, bottom = 0, z = 0;
        QString color;
        for (const QVariant& v : nodes) {
            const QVariantMap n = v.toMap();
            const QVariantMap st = n.value(QStringLiteral("style")).toMap();
            const QVariantMap data = n.value(QStringLiteral("data")).toMap();
            z = qMax(z, num(st, "z"));
            if (!column.contains(n.value(QStringLiteral("id")).toString())) continue;
            if (data.contains(QStringLiteral("group"))) hasCard = true;
            if (n.value(QStringLiteral("kind")).toString() != QLatin1String("text")) continue;
            top = qMin(top, num(st, "y"));
            bottom = qMax(bottom, num(st, "y") + num(st, "height"));
            if (data.value(QStringLiteral("linkage")).toString() == QLatin1String("scriptureText"))
                color = st.value(QStringLiteral("color")).toString();
        }
        // #rgb / #rrggbb / #aarrggbb -> #40rrggbb
        QString rgb = color.startsWith(QLatin1Char('#')) ? color.mid(1) : QString();
        if (rgb.size() == 3) rgb = QString(rgb[0]) + rgb[0] + rgb[1] + rgb[1] + rgb[2] + rgb[2];
        if (rgb.size() == 8) rgb = rgb.mid(2);
        if (rgb.size() != 6) rgb = QStringLiteral("ffffff");
        if (!hasCard && bottom > top) {
            constexpr double kWidth = 0.12;
            divider = QVariantMap{
                { QStringLiteral("id"),    QStringLiteral("split-divider") },
                { QStringLiteral("kind"),  QStringLiteral("container") },
                { QStringLiteral("style"), QVariantMap{
                      { QStringLiteral("x"), 50 - kWidth / 2 }, { QStringLiteral("y"), top },
                      { QStringLiteral("width"), kWidth }, { QStringLiteral("height"), bottom - top },
                      { QStringLiteral("z"), z }, { QStringLiteral("opacity"), 1 },
                      { QStringLiteral("backgroundColor"), QStringLiteral("#40") + rgb } } },
                { QStringLiteral("data"),  QVariantMap{
                      { QStringLiteral("layerName"), QStringLiteral("Split divider") } } },
            };
        }
    }

    QVariantList out;
    for (const QVariant& v : nodes) {
        const QVariantMap n = v.toMap();
        const QString id = n.value(QStringLiteral("id")).toString();
        if (!column.contains(id)) { out.append(n); continue; }

        out.append(place(n, x0));

        QVariantMap r = place(n, rightStart);
        r.insert(QStringLiteral("id"), id + suffix);
        QVariantMap data = r.value(QStringLiteral("data")).toMap();
        const QString linkage = data.value(QStringLiteral("linkage")).toString();
        if (isScriptureTextLinkage(linkage))
            data.insert(QStringLiteral("linkage"), linkage + QStringLiteral("Right"));
        if (data.contains(QStringLiteral("layerName")))
            data.insert(QStringLiteral("layerName"),
                        data.value(QStringLiteral("layerName")).toString() + QStringLiteral(" (right)"));
        if (data.contains(QStringLiteral("group"))) {
            QVariantMap g = data.value(QStringLiteral("group")).toMap();
            QVariantList members;
            for (const QVariant& m : g.value(QStringLiteral("members")).toList())
                members << renamed(m.toString());
            g.insert(QStringLiteral("members"), members);
            data.insert(QStringLiteral("group"), g);
        }
        for (const char* rule : { "autoHeight", "autoPosition" }) {
            const QString key = QString::fromLatin1(rule);
            if (!data.contains(key)) continue;
            QVariantMap m = data.value(key).toMap();
            for (const char* k : { "source", "from", "to" }) {
                const QString kk = QString::fromLatin1(k);
                if (m.contains(kk)) m.insert(kk, renamed(m.value(kk).toString()));
            }
            data.insert(key, m);
        }
        r.insert(QStringLiteral("data"), data);
        out.append(r);
    }
    if (!divider.isEmpty()) out.append(divider);
    return out;
}

QVariantList layoutNodes(const QVariantMap& tokens,
                         const QString&     layoutId,
                         qint64             slideMediaId)
{
    // A split slide on a theme with no split design of its own.
    if (layoutId == QLatin1String(kLayoutSplit) && !hasLayout(tokens, layoutId))
        return deriveSplitNodes(resolveLayout(tokens, QString()).value(QStringLiteral("nodes")).toList());

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
