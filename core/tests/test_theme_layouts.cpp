// Tests for theme token LAYOUTS (crater/ThemeTokens.h) — the v3 shape that
// lets one presentation theme carry several designs the way a PowerPoint
// template does.
//
// Pure data in, pure data out: no database, no Gui, no QML. That is the
// whole reason this logic was pulled into crater::tokens instead of living
// inside ThemeService — the interesting cases here are cheap to state and
// would otherwise only be reachable by clicking through a running app.
//
// The case that matters most is resolveLayout()'s FALLBACK. A deck stores
// the layout id it was authored with, but Crater lets the theme underneath
// it change at any moment (per-deck override, per-output slot, per-kind
// default, all swappable mid-service). So a slide asking for "section"
// will routinely be handed a theme that has never heard of it, and the
// only acceptable answer is that theme's default design — not a blank
// screen, and not a refusal to switch theme.
//
// Run via CTest: `ctest --test-dir <build-dir> -R theme_layouts --output-on-failure`

#include <QObject>
#include <QTest>
#include <QVariantList>
#include <QVariantMap>

#include "crater/ThemeTokens.h"

namespace tk = crater::tokens;

namespace {

QVariantMap textNode(const QString& id, const QString& linkage)
{
    return QVariantMap{
        { QStringLiteral("id"),    id },
        { QStringLiteral("kind"),  QStringLiteral("text") },
        { QStringLiteral("style"), QVariantMap{ { QStringLiteral("color"), QStringLiteral("#ffffff") } } },
        { QStringLiteral("data"),  QVariantMap{ { QStringLiteral("linkage"), linkage } } },
    };
}

QVariantMap containerNode(const QString& id, const QString& linkage = {})
{
    QVariantMap data;
    if (!linkage.isEmpty()) data.insert(QStringLiteral("linkage"), linkage);
    return QVariantMap{
        { QStringLiteral("id"),    id },
        { QStringLiteral("kind"),  QStringLiteral("container") },
        { QStringLiteral("style"), QVariantMap{} },
        { QStringLiteral("data"),  data },
    };
}

QVariantMap layout(const QString& id, const QString& name,
                   const QVariantList& nodes, bool isDefault = false)
{
    QVariantMap l{
        { QStringLiteral("id"),    id },
        { QStringLiteral("name"),  name },
        { QStringLiteral("nodes"), nodes },
    };
    if (isDefault) l.insert(QStringLiteral("default"), true);
    return l;
}

// A v2 theme: one bare `nodes` array, no layouts. This is what every theme
// in every existing install looks like.
QVariantMap v2Theme()
{
    return QVariantMap{
        { QStringLiteral("version"), 2 },
        { QStringLiteral("canvas"),  QVariantMap{ { QStringLiteral("width"),  1920 },
                                                  { QStringLiteral("height"), 1080 } } },
        { QStringLiteral("nodes"),   QVariantList{
              containerNode(QStringLiteral("bg")),
              textNode(QStringLiteral("title"), QStringLiteral("presentationTitle")),
              textNode(QStringLiteral("body"),  QStringLiteral("presentationBody")) } },
    };
}

// A v3 theme with three designs; "content" is flagged default, and it is
// deliberately NOT first in the array so "falls back to default" and
// "falls back to first" cannot pass for the same reason.
QVariantMap v3Theme()
{
    return QVariantMap{
        { QStringLiteral("version"), 3 },
        { QStringLiteral("canvas"),  QVariantMap{ { QStringLiteral("width"),  1920 },
                                                  { QStringLiteral("height"), 1080 } } },
        { QStringLiteral("layouts"), QVariantList{
              layout(QStringLiteral("title"), QStringLiteral("Title slide"),
                     { textNode(QStringLiteral("t"), QStringLiteral("presentationTitle")),
                       textNode(QStringLiteral("s"), QStringLiteral("presentationSubtitle")) }),
              layout(QStringLiteral("content"), QStringLiteral("Title + content"),
                     { textNode(QStringLiteral("t"), QStringLiteral("presentationTitle")),
                       textNode(QStringLiteral("b"), QStringLiteral("presentationBody")) },
                     /*isDefault=*/true),
              layout(QStringLiteral("picture"), QStringLiteral("Picture"),
                     { containerNode(QStringLiteral("pic"), QStringLiteral("presentationImage")),
                       textNode(QStringLiteral("t"), QStringLiteral("presentationTitle")) }) } },
    };
}

QStringList idsOf(const QVariantList& layouts)
{
    QStringList out;
    for (const QVariant& v : layouts) out << v.toMap().value(QStringLiteral("id")).toString();
    return out;
}

}  // namespace

class TestThemeLayouts : public QObject
{
    Q_OBJECT

private slots:
    // ── v2 compatibility ────────────────────────────────────────────────

    // Every render surface calls layoutsOf() without checking the version,
    // so a v2 theme has to read as exactly one layout rather than as none.
    void v2ReadsAsOneImplicitLayout()
    {
        const QVariantList ls = tk::layoutsOf(v2Theme());
        QCOMPARE(ls.size(), 1);
        const QVariantMap only = ls.first().toMap();
        QCOMPARE(only.value("id").toString(), QStringLiteral("content"));
        QVERIFY(only.value("default").toBool());
        QCOMPARE(only.value("nodes").toList().size(), 3);
    }

    // The implicit layout must carry the ACTUAL nodes, not an empty stub —
    // otherwise an un-migrated theme renders a blank screen.
    void v2ImplicitLayoutKeepsItsNodes()
    {
        const QVariantList nodes = tk::layoutNodes(v2Theme(), QString());
        QCOMPARE(nodes.size(), 3);
        QCOMPARE(nodes.at(1).toMap().value("id").toString(), QStringLiteral("title"));
    }

    // Tokens with neither layouts nor nodes are degenerate, not a crash.
    void emptyTokensResolveToNothing()
    {
        QVERIFY(tk::layoutsOf(QVariantMap{}).isEmpty());
        QVERIFY(tk::resolveLayout(QVariantMap{}, QStringLiteral("title")).isEmpty());
        QVERIFY(tk::layoutNodes(QVariantMap{}, QStringLiteral("title")).isEmpty());
    }

    // ── Resolution ──────────────────────────────────────────────────────

    void resolvesByExactId()
    {
        const QVariantMap l = tk::resolveLayout(v3Theme(), QStringLiteral("picture"));
        QCOMPARE(l.value("id").toString(), QStringLiteral("picture"));
    }

    // An empty layout id is what every pre-v3 slide carries, and what a
    // song or scripture item always passes. It means "this theme's default".
    void emptyIdResolvesToDefault()
    {
        const QVariantMap l = tk::resolveLayout(v3Theme(), QString());
        QCOMPARE(l.value("id").toString(), QStringLiteral("content"));
    }

    // THE case this file exists for: a deck authored under one theme,
    // projected under another that has no such design. Falling back beats
    // rendering nothing, and the id stays stored so switching back restores
    // the intended look.
    void unknownIdFallsBackToDefault()
    {
        const QVariantMap l = tk::resolveLayout(v3Theme(), QStringLiteral("quote"));
        QCOMPARE(l.value("id").toString(), QStringLiteral("content"));
        QVERIFY(!tk::layoutNodes(v3Theme(), QStringLiteral("quote")).isEmpty());
    }

    // With no design flagged default, the first one wins. A hand-authored
    // theme that omits the flag must still work.
    void noDefaultFlagFallsBackToFirst()
    {
        QVariantMap t = v3Theme();
        QVariantList ls = t.value("layouts").toList();
        for (int i = 0; i < ls.size(); ++i) {
            QVariantMap l = ls[i].toMap();
            l.remove(QStringLiteral("default"));
            ls[i] = l;
        }
        t[QStringLiteral("layouts")] = ls;

        const QVariantMap l = tk::resolveLayout(t, QStringLiteral("nope"));
        QCOMPARE(l.value("id").toString(), QStringLiteral("title"));
    }

    // hasLayout distinguishes "chosen" from "fell back", which is what lets
    // the slide editor warn instead of silently showing the wrong design.
    void hasLayoutIsExactNotResolved()
    {
        QVERIFY(tk::hasLayout(v3Theme(),  QStringLiteral("picture")));
        QVERIFY(!tk::hasLayout(v3Theme(), QStringLiteral("quote")));
        QVERIFY(!tk::hasLayout(v3Theme(), QString()));
        // A v2 theme really does define "content" once read through layoutsOf.
        QVERIFY(tk::hasLayout(v2Theme(), QStringLiteral("content")));
    }

    // ── Derived slots ───────────────────────────────────────────────────

    void slotsAreDerivedFromLinkages()
    {
        const QVariantMap s = tk::layoutSlotsFor(v3Theme(), QStringLiteral("title"));
        QVERIFY(s.value("title").toBool());
        QVERIFY(s.value("subtitle").toBool());
        QVERIFY(!s.value("body").toBool());
        QVERIFY(!s.value("bodyRight").toBool());
        QVERIFY(!s.value("image").toBool());
    }

    // The picture slot rides on a CONTAINER linkage, not a text one — the
    // container already knows how to paint media, it just takes the id from
    // the slide instead of from the theme.
    void pictureSlotComesFromAContainer()
    {
        const QVariantMap s = tk::layoutSlotsFor(v3Theme(), QStringLiteral("picture"));
        QVERIFY(s.value("image").toBool());
        QVERIFY(s.value("title").toBool());
        QVERIFY(!s.value("body").toBool());
    }

    // Every key is always present, so QML can read slots.body without an
    // undefined check on a design that happens not to use it.
    void slotsAlwaysReportEveryKey()
    {
        const QVariantMap s = tk::layoutSlots(QVariantMap{});
        for (const char* k : { "title", "body", "subtitle", "bodyRight", "image" }) {
            QVERIFY2(s.contains(QLatin1String(k)), k);
            QVERIFY2(!s.value(QLatin1String(k)).toBool(), k);
        }
    }

    // ── Upgrade ─────────────────────────────────────────────────────────

    void upgradeWrapsV2NodesIntoOneLayout()
    {
        const QVariantMap up = tk::upgradeToV3(v2Theme());
        QCOMPARE(up.value("version").toInt(), 3);
        QCOMPARE(up.value("canvas").toMap().value("width").toInt(), 1920);
        QCOMPARE(up.value("layouts").toList().size(), 1);
        QCOMPARE(up.value("layouts").toList().first().toMap()
                   .value("nodes").toList().size(), 3);
    }

    // The trap V010's migration comment documents, one version up: a row can
    // hold v3 JSON while its tokens_version column still reads 2. Wrapping
    // twice would bury every design a level deeper and lose all of them.
    void upgradeIsIdempotent()
    {
        const QVariantMap once  = tk::upgradeToV3(v2Theme());
        const QVariantMap twice = tk::upgradeToV3(once);
        QCOMPARE(idsOf(twice.value("layouts").toList()),
                 idsOf(once.value("layouts").toList()));
        QCOMPARE(twice.value("layouts").toList().size(), 1);
    }

    // Same guard, reached the other way: correct JSON, stale version field.
    void upgradeRespectsLayoutsOverStaleVersionField()
    {
        QVariantMap stale = v3Theme();
        stale[QStringLiteral("version")] = 2;      // column/JSON drift

        const QVariantMap up = tk::upgradeToV3(stale);
        QCOMPARE(up.value("version").toInt(), 3);
        QCOMPARE(idsOf(up.value("layouts").toList()),
                 (QStringList{ QStringLiteral("title"),
                               QStringLiteral("content"),
                               QStringLiteral("picture") }));
    }

    // Upgrading must not change what renders. A v2 theme's nodes have to
    // come back out of the default layout byte-identical.
    void upgradePreservesRenderedNodes()
    {
        const QVariantMap src = v2Theme();
        const QVariantList before = src.value("nodes").toList();
        const QVariantList after  = tk::layoutNodes(tk::upgradeToV3(src), QString());
        QCOMPARE(after, before);
    }

    // ── Vocabulary ──────────────────────────────────────────────────────

    void standardIdsAllHaveNames()
    {
        const QStringList ids = tk::standardLayoutIds();
        QVERIFY(!ids.isEmpty());
        for (const QString& id : ids) {
            const QString name = tk::defaultLayoutName(id);
            QVERIFY2(!name.isEmpty(), qPrintable(id));
            QVERIFY2(name != id, qPrintable(id));   // a real label, not the slug
        }
    }

    // A custom id from the visual editor still renders something in a
    // picker rather than an empty row.
    void customIdNamesItself()
    {
        QCOMPARE(tk::defaultLayoutName(QStringLiteral("myDesign")),
                 QStringLiteral("myDesign"));
    }
};

QTEST_APPLESS_MAIN(TestThemeLayouts)
#include "test_theme_layouts.moc"
