#include <QtTest>

#include "crater/ThemeTokens.h"
#include "crater/WorkingTheme.h"

using namespace crater;

namespace {

QVariantMap textNode(const QString& id, const QString& linkage, int fontPx = 40)
{
    QVariantMap style{
        { "x", 5 }, { "y", 10 }, { "width", 90 }, { "height", 20 }, { "z", 10 },
        { "opacity", 1 }, { "color", QStringLiteral("#f5f5f0") },
        { "fontFamily", QStringLiteral("Inter") }, { "fontPixelSize", fontPx },
        { "fontWeight", 500 }, { "textAlign", QStringLiteral("left") },
        { "verticalAlign", QStringLiteral("center") },
    };
    QVariantMap data{
        { "layerName", id }, { "linkage", linkage },
        { "autoResize", true }, { "maxFontSize", 220 },
    };
    return QVariantMap{ { "id", id }, { "kind", QStringLiteral("text") },
                        { "style", style }, { "data", data } };
}

QVariantMap containerNode(const QString& id, const QString& layerName)
{
    QVariantMap style{
        { "x", 0 }, { "y", 0 }, { "width", 100 }, { "height", 100 }, { "z", 0 },
        { "opacity", 1 }, { "backgroundColor", QStringLiteral("#0a0a0d") },
    };
    QVariantMap data{ { "layerName", layerName }, { "bgOpacity", 1 } };
    return QVariantMap{ { "id", id }, { "kind", QStringLiteral("container") },
                        { "style", style }, { "data", data } };
}

QVariantMap layoutOf(const QString& id, const QString& name, bool isDefault,
                     const QVariantList& nodes)
{
    return QVariantMap{ { "id", id }, { "name", name },
                        { "default", isDefault }, { "nodes", nodes } };
}

// A two-layout v3 theme: a branded default (background + title + body) and a
// bare section divider.
QVariantMap twoLayoutTokens()
{
    const QVariantList contentNodes{
        containerNode(QStringLiteral("bg"), QStringLiteral("Background")),
        textNode(QStringLiteral("t1"), QStringLiteral("presentationTitle"), 60),
        textNode(QStringLiteral("b1"), QStringLiteral("presentationBody"),  40),
    };
    const QVariantList sectionNodes{
        containerNode(QStringLiteral("bg2"), QStringLiteral("Background")),
        textNode(QStringLiteral("t2"), QStringLiteral("presentationTitle"), 84),
    };
    return QVariantMap{
        { "version", 3 },
        { "canvas",  QVariantMap{ { "width", 1920 }, { "height", 1080 } } },
        { "layouts", QVariantList{
            layoutOf(QStringLiteral("content"), QStringLiteral("Title + content"),
                     true, contentNodes),
            layoutOf(QStringLiteral("section"), QStringLiteral("Section divider"),
                     false, sectionNodes) } },
    };
}

QStringList linkagesIn(const QVariantList& nodes)
{
    QStringList out;
    for (const QVariant& v : nodes) {
        const QVariantMap n = v.toMap();
        const QString lk = n.value("data").toMap().value("linkage").toString();
        if (!lk.isEmpty()) out << lk;
    }
    out.sort();
    return out;
}

QStringList idsIn(const QVariantList& nodes)
{
    QStringList out;
    for (const QVariant& v : nodes) out << v.toMap().value("id").toString();
    return out;
}

QVariantList nodesOfLayout(const WorkingTheme& wt, const QString& layoutId)
{
    return wt.layout(layoutId).value("nodes").toList();
}

}  // namespace

// Covers the editor's working copy once it grew from one flat node list to a
// set of named layouts. The failure modes worth a test here are the quiet
// ones: an edit landing in the wrong design, a save dropping the designs the
// author was not looking at, and an undo bouncing them out of the design they
// were working on.
class TestWorkingTheme : public QObject
{
    Q_OBJECT

private slots:

    // ── Shape ──────────────────────────────────────────────────────────

    void constructsWithOneUsableLayout()
    {
        WorkingTheme wt;
        QCOMPARE(wt.layouts().size(), 1);
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("content"));
        // addNode has to work on a freshly constructed instance, which it
        // only does if there is a layout to put the node in.
        const QString id = wt.addNode(QStringLiteral("text"));
        QVERIFY(!id.isEmpty());
        QCOMPARE(wt.nodes().size(), 1);
    }

    void loadsV2AsOneImplicitLayout()
    {
        QVariantMap v2{
            { "version", 2 },
            { "canvas",  QVariantMap{ { "width", 1920 }, { "height", 1080 } } },
            { "nodes",   QVariantList{
                containerNode(QStringLiteral("bg"), QStringLiteral("Background")),
                textNode(QStringLiteral("t"), QStringLiteral("lyric")) } },
        };

        WorkingTheme wt;
        wt.loadFrom(v2);

        QCOMPARE(wt.layouts().size(), 1);
        QCOMPARE(wt.nodes().size(), 2);
        // ...and it saves back as v3, so opening an un-migrated theme in the
        // editor and pressing Save is itself the migration.
        QCOMPARE(wt.toTokens().value("version").toInt(), 3);
        QVERIFY(wt.toTokens().contains("layouts"));
    }

    void toTokensKeepsEveryLayout()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        const QVariantList out = wt.toTokens().value("layouts").toList();
        QCOMPARE(out.size(), 2);
        QCOMPARE(out[0].toMap().value("id").toString(), QStringLiteral("content"));
        QCOMPARE(out[1].toMap().value("id").toString(), QStringLiteral("section"));
    }

    // ── Read-through ───────────────────────────────────────────────────

    void nodesFollowTheCurrentLayout()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        QCOMPARE(wt.nodes().size(), 3);

        wt.setCurrentLayout(QStringLiteral("section"));
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
        QCOMPARE(wt.nodes().size(), 2);

        // An id from the other design is simply not here.
        QVERIFY(wt.node(QStringLiteral("b1")).isEmpty());
        QCOMPARE(wt.indexOf(QStringLiteral("b1")), -1);
    }

    void switchingLayoutEmitsNodesChanged()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        QSignalSpy nodesSpy(&wt, &WorkingTheme::nodesChanged);
        QSignalSpy curSpy (&wt, &WorkingTheme::currentLayoutChanged);

        wt.setCurrentLayout(QStringLiteral("section"));
        QCOMPARE(nodesSpy.count(), 1);
        QCOMPARE(curSpy.count(),   1);

        // Switching to the layout already current is a no-op: the canvas is
        // already drawing it, and re-emitting would rebuild every delegate.
        wt.setCurrentLayout(QStringLiteral("section"));
        QCOMPARE(nodesSpy.count(), 1);
        // An unknown id is refused rather than clearing the selection.
        wt.setCurrentLayout(QStringLiteral("nope"));
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
        QCOMPARE(nodesSpy.count(), 1);
    }

    // The one that matters most: a node edit must land in the layout being
    // edited and leave the others untouched. Read-through exists to make
    // this impossible to get wrong, so it is worth asserting directly.
    void editsLandInTheCurrentLayoutOnly()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());

        wt.setCurrentLayout(QStringLiteral("section"));
        wt.setNodeStyle(QStringLiteral("t2"), QStringLiteral("fontPixelSize"), 120);
        wt.renameNode (QStringLiteral("t2"), QStringLiteral("Divider heading"));
        const QString added = wt.addNode(QStringLiteral("container"));

        const QVariantList section = nodesOfLayout(wt, QStringLiteral("section"));
        const QVariantList content = nodesOfLayout(wt, QStringLiteral("content"));

        QCOMPARE(section.size(), 3);                 // gained the container
        QCOMPARE(content.size(), 3);                 // untouched
        QVERIFY(idsIn(section).contains(added));
        QVERIFY(!idsIn(content).contains(added));

        wt.setCurrentLayout(QStringLiteral("section"));
        QCOMPARE(wt.node(QStringLiteral("t2")).value("style").toMap()
                   .value("fontPixelSize").toInt(), 120);

        // And the OTHER design's same-named field is where it started.
        wt.setCurrentLayout(QStringLiteral("content"));
        QCOMPARE(wt.node(QStringLiteral("t1")).value("style").toMap()
                   .value("fontPixelSize").toInt(), 60);
    }

    void removeAndReorderStayWithinTheLayout()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.setCurrentLayout(QStringLiteral("section"));
        wt.removeNode(QStringLiteral("t2"));

        QCOMPARE(nodesOfLayout(wt, QStringLiteral("section")).size(), 1);
        QCOMPARE(nodesOfLayout(wt, QStringLiteral("content")).size(), 3);
    }

    // ── Selection across a reload (undo / redo) ────────────────────────

    // Opening a theme has to land on the design it flags default. The
    // constructor seeds a placeholder layout whose id is "content", and most
    // presentation themes define a design by that name, so preserving the
    // selection across the FIRST load would silently open every theme on its
    // Title + content design no matter what it declared.
    void firstLoadOpensOnTheDefaultDesign()
    {
        QVariantMap themeTokens = twoLayoutTokens();
        QVariantList ls = themeTokens.value("layouts").toList();
        QVariantMap content = ls[0].toMap();
        QVariantMap section = ls[1].toMap();
        content["default"] = false;
        section["default"] = true;
        ls[0] = content;
        ls[1] = section;
        themeTokens["layouts"] = ls;

        WorkingTheme wt;
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("content"));   // placeholder
        wt.loadFrom(themeTokens);
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
    }

    void loadFromKeepsTheCurrentLayoutWhenItSurvives()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.setCurrentLayout(QStringLiteral("section"));

        // What undo does: reload a whole-theme snapshot. The author was
        // editing the section divider and must still be looking at it.
        wt.loadFrom(twoLayoutTokens());
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
    }

    void loadFromFallsBackToDefaultWhenTheLayoutIsGone()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.setCurrentLayout(QStringLiteral("section"));

        // Undoing past the point the section divider was added.
        QVariantMap earlier = twoLayoutTokens();
        QVariantList only{ earlier.value("layouts").toList().first() };
        earlier["layouts"] = only;
        wt.loadFrom(earlier);

        QCOMPARE(wt.currentLayoutId(), QStringLiteral("content"));
        QCOMPARE(wt.nodes().size(), 3);
    }

    void loadFromWithNothingUsableStillLeavesOneLayout()
    {
        WorkingTheme wt;
        wt.loadFrom(QVariantMap{ { "version", 3 } });
        QCOMPARE(wt.layouts().size(), 1);
        QVERIFY(!wt.currentLayoutId().isEmpty());
    }

    // ── Adding a design ────────────────────────────────────────────────

    void addLayoutInheritsChromeAndSwapsContent()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());

        const QString id = wt.addLayout(QStringLiteral("twoColumn"), QString());
        QCOMPARE(id, QStringLiteral("twoColumn"));

        const QVariantList made = nodesOfLayout(wt, id);
        // The default layout's background carried across by id...
        QVERIFY(idsIn(made).contains(QStringLiteral("bg")));
        // ...its content text nodes did not.
        QVERIFY(!idsIn(made).contains(QStringLiteral("t1")));
        QVERIFY(!idsIn(made).contains(QStringLiteral("b1")));
        // ...and the new design binds exactly the slots two columns needs.
        QCOMPARE(linkagesIn(made), (QStringList{ QStringLiteral("presentationBody"),
                                                 QStringLiteral("presentationBodyRight"),
                                                 QStringLiteral("presentationTitle") }));

        const QVariantMap boundSlots =
            tokens::layoutSlotsFor(wt.toTokens(), id);
        QVERIFY(boundSlots.value("title").toBool());
        QVERIFY(boundSlots.value("body").toBool());
        QVERIFY(boundSlots.value("bodyRight").toBool());
        QVERIFY(!boundSlots.value("image").toBool());
    }

    // A new design that starts as the editor's hardcoded white-on-nothing is
    // a design the author has to restyle by hand, which is the opposite of
    // what a template is for.
    void addLayoutBorrowsTheThemesTextStyling()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        const QString id = wt.addLayout(QStringLiteral("title"), QString());

        for (const QVariant& v : nodesOfLayout(wt, id)) {
            const QVariantMap n = v.toMap();
            if (n.value("kind").toString() != QLatin1String("text")) continue;
            const QVariantMap s = n.value("style").toMap();
            QCOMPARE(s.value("color").toString(),      QStringLiteral("#f5f5f0"));
            QCOMPARE(s.value("fontFamily").toString(), QStringLiteral("Inter"));
        }
    }

    void addLayoutBuildsThePictureSlotAsAContainer()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        const QString id = wt.addLayout(QStringLiteral("picture"), QString());

        const QVariantMap boundSlots = tokens::layoutSlotsFor(wt.toTokens(), id);
        QVERIFY(boundSlots.value("image").toBool());

        int placeholders = 0;
        for (const QVariant& v : nodesOfLayout(wt, id)) {
            const QVariantMap n = v.toMap();
            if (n.value("data").toMap().value("linkage").toString()
                == QLatin1String("presentationImage")) {
                QCOMPARE(n.value("kind").toString(), QStringLiteral("container"));
                ++placeholders;
            }
        }
        QCOMPARE(placeholders, 1);
    }

    void addLayoutRefusesADuplicateIdAndMintsACustomOne()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());

        QVERIFY(wt.addLayout(QStringLiteral("section"), QString()).isEmpty());
        QCOMPARE(wt.layouts().size(), 2);

        const QString custom = wt.addLayout(QString(), QStringLiteral("Sermon point"));
        QVERIFY(custom.startsWith(QStringLiteral("custom_")));
        QCOMPARE(wt.layout(custom).value("name").toString(),
                 QStringLiteral("Sermon point"));
        // A custom design is never silently promoted over the author's default.
        QVERIFY(!wt.layout(custom).value("default").toBool());
    }

    void addLayoutNamesStandardIdsWithoutBeingTold()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.addLayout(QStringLiteral("quote"), QString());
        QCOMPARE(wt.layout(QStringLiteral("quote")).value("name").toString(),
                 QStringLiteral("Quote"));
    }

    // A card container hugs the nodes it lists. Carried over verbatim, its
    // members would all be gone and it would collapse to a sliver of padding.
    void addLayoutRepointsAContentCardAtTheNewText()
    {
        QVariantMap card = containerNode(QStringLiteral("card"), QStringLiteral("Card"));
        QVariantMap data = card.value("data").toMap();
        data["group"] = QVariantMap{
            { "members", QStringList{ QStringLiteral("t1"), QStringLiteral("b1") } },
            { "gap", 2 }, { "padTop", 4 }, { "padBottom", 4 }, { "padX", 4 },
        };
        card["data"] = data;

        QVariantMap themeTokens{
            { "version", 3 },
            { "canvas",  QVariantMap{ { "width", 1920 }, { "height", 1080 } } },
            { "layouts", QVariantList{ layoutOf(
                QStringLiteral("content"), QStringLiteral("Title + content"), true,
                QVariantList{
                    containerNode(QStringLiteral("bg"), QStringLiteral("Background")),
                    card,
                    textNode(QStringLiteral("t1"), QStringLiteral("presentationTitle")),
                    textNode(QStringLiteral("b1"), QStringLiteral("presentationBody")) }) } },
        };

        WorkingTheme wt;
        wt.loadFrom(themeTokens);
        const QString id = wt.addLayout(QStringLiteral("title"), QString());

        const QVariantList made = nodesOfLayout(wt, id);
        QStringList newText;
        for (const QVariant& v : made) {
            const QVariantMap n = v.toMap();
            if (n.value("kind").toString() == QLatin1String("text"))
                newText << n.value("id").toString();
        }
        QCOMPARE(newText.size(), 2);                      // title + subtitle

        bool sawCard = false;
        for (const QVariant& v : made) {
            const QVariantMap n = v.toMap();
            const QVariantMap g = n.value("data").toMap().value("group").toMap();
            if (g.isEmpty()) continue;
            sawCard = true;
            const QStringList members = g.value("members").toStringList();
            QCOMPARE(members, newText);                   // repointed, in order
            QVERIFY(!members.contains(QStringLiteral("t1")));
        }
        QVERIFY(sawCard);
    }

    // Validation refuses an empty node list, so "Blank" added to a theme with
    // no chrome to inherit still has to produce something to click.
    void addLayoutNeverProducesAnEmptyDesign()
    {
        QVariantMap bare{
            { "version", 3 },
            { "canvas",  QVariantMap{ { "width", 1920 }, { "height", 1080 } } },
            { "layouts", QVariantList{ layoutOf(
                QStringLiteral("content"), QStringLiteral("Title + content"), true,
                QVariantList{ textNode(QStringLiteral("t1"),
                                       QStringLiteral("presentationTitle")) }) } },
        };

        WorkingTheme wt;
        wt.loadFrom(bare);
        const QString id = wt.addLayout(QStringLiteral("blank"), QString());
        QVERIFY(!nodesOfLayout(wt, id).isEmpty());
    }

    void unusedStandardIdsShrinkAsDesignsAreAdded()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());

        QStringList unused = wt.unusedStandardLayoutIds();
        QCOMPARE(unused.size(), tokens::standardLayoutIds().size() - 2);
        QVERIFY(!unused.contains(QStringLiteral("content")));
        QVERIFY(!unused.contains(QStringLiteral("section")));
        QVERIFY(unused.contains(QStringLiteral("quote")));

        wt.addLayout(QStringLiteral("quote"), QString());
        QVERIFY(!wt.unusedStandardLayoutIds().contains(QStringLiteral("quote")));
    }

    // ── Duplicating ────────────────────────────────────────────────────

    void duplicateLayoutRemintsNodeIdsAndFollowsGroups()
    {
        QVariantMap card = containerNode(QStringLiteral("card"), QStringLiteral("Card"));
        QVariantMap data = card.value("data").toMap();
        data["group"] = QVariantMap{
            { "members", QStringList{ QStringLiteral("t1") } }, { "gap", 2 } };
        card["data"] = data;

        QVariantMap themeTokens{
            { "version", 3 },
            { "canvas",  QVariantMap{ { "width", 1920 }, { "height", 1080 } } },
            { "layouts", QVariantList{ layoutOf(
                QStringLiteral("content"), QStringLiteral("Title + content"), true,
                QVariantList{ card, textNode(QStringLiteral("t1"),
                                             QStringLiteral("presentationTitle")) }) } },
        };

        WorkingTheme wt;
        wt.loadFrom(themeTokens);
        const QString copyId = wt.duplicateLayout(QStringLiteral("content"));
        QVERIFY(!copyId.isEmpty());
        QCOMPARE(wt.layouts().size(), 2);
        QCOMPARE(wt.layout(copyId).value("name").toString(),
                 QStringLiteral("Title + content Copy"));
        QVERIFY(!wt.layout(copyId).value("default").toBool());

        const QVariantList copied = nodesOfLayout(wt, copyId);
        QCOMPARE(copied.size(), 2);
        QVERIFY(!idsIn(copied).contains(QStringLiteral("t1")));   // re-minted
        QVERIFY(!idsIn(copied).contains(QStringLiteral("card")));

        // The card must hug the COPY's text, not the original's.
        for (const QVariant& v : copied) {
            const QVariantMap g = v.toMap().value("data").toMap()
                                   .value("group").toMap();
            if (g.isEmpty()) continue;
            const QStringList members = g.value("members").toStringList();
            QCOMPARE(members.size(), 1);
            QVERIFY(idsIn(copied).contains(members.first()));
            QVERIFY(members.first() != QStringLiteral("t1"));
        }
    }

    void duplicateLayoutLandsNextToItsSource()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        const QString copyId = wt.duplicateLayout(QStringLiteral("content"));
        QCOMPARE(wt.indexOfLayout(copyId), 1);
        QCOMPARE(wt.indexOfLayout(QStringLiteral("section")), 2);
        // The author was editing "content" and still is.
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("content"));
    }

    // ── Removing ───────────────────────────────────────────────────────

    void removeLayoutRefusesTheLastOne()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.removeLayout(QStringLiteral("section"));
        QCOMPARE(wt.layouts().size(), 1);

        wt.removeLayout(QStringLiteral("content"));
        QCOMPARE(wt.layouts().size(), 1);          // a theme needs one design
    }

    void removingTheDefaultPromotesASurvivor()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.removeLayout(QStringLiteral("content"));      // the default

        QCOMPARE(wt.layouts().size(), 1);
        QVERIFY(wt.layout(QStringLiteral("section")).value("default").toBool());
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
        // And `nodes` followed, rather than reading through a dead index.
        QCOMPARE(wt.nodes().size(), 2);
    }

    void removingAnUnselectedLayoutLeavesTheSelectionAlone()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.setCurrentLayout(QStringLiteral("section"));
        wt.addLayout(QStringLiteral("quote"), QString());

        wt.removeLayout(QStringLiteral("quote"));
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
    }

    // ── Default / rename / reorder ─────────────────────────────────────

    void exactlyOneLayoutIsEverDefault()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.setDefaultLayout(QStringLiteral("section"));

        int defaults = 0;
        for (const QVariant& v : wt.layouts())
            if (v.toMap().value("default").toBool()) ++defaults;
        QCOMPARE(defaults, 1);
        QVERIFY(wt.layout(QStringLiteral("section")).value("default").toBool());
    }

    // Two defaults resolve to whichever comes first in the array, silently.
    // Loading a hand-edited theme has to fix that rather than carry it.
    void loadFromNormalizesAStrayExtraDefault()
    {
        QVariantMap themeTokens = twoLayoutTokens();
        QVariantList ls = themeTokens.value("layouts").toList();
        QVariantMap second = ls[1].toMap();
        second["default"] = true;
        ls[1] = second;
        themeTokens["layouts"] = ls;

        WorkingTheme wt;
        wt.loadFrom(themeTokens);

        int defaults = 0;
        for (const QVariant& v : wt.layouts())
            if (v.toMap().value("default").toBool()) ++defaults;
        QCOMPARE(defaults, 1);
    }

    void loadFromPromotesAFirstDefaultWhenNoneIsFlagged()
    {
        QVariantMap themeTokens = twoLayoutTokens();
        QVariantList ls = themeTokens.value("layouts").toList();
        QVariantMap first = ls[0].toMap();
        first["default"] = false;
        ls[0] = first;
        themeTokens["layouts"] = ls;

        WorkingTheme wt;
        wt.loadFrom(themeTokens);
        QVERIFY(wt.layout(QStringLiteral("content")).value("default").toBool());
    }

    void renameLayoutRejectsAnEmptyName()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.renameLayout(QStringLiteral("section"), QStringLiteral("   "));
        // A nameless design is unpickable in both editors, so the rename is
        // refused rather than stored and rendered as a blank row.
        QCOMPARE(wt.layout(QStringLiteral("section")).value("name").toString(),
                 QStringLiteral("Section divider"));

        wt.renameLayout(QStringLiteral("section"), QStringLiteral("  Divider  "));
        QCOMPARE(wt.layout(QStringLiteral("section")).value("name").toString(),
                 QStringLiteral("Divider"));
    }

    void moveLayoutReordersAndCarriesTheSelection()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.setCurrentLayout(QStringLiteral("section"));

        wt.moveLayout(QStringLiteral("section"), -1);
        QCOMPARE(wt.indexOfLayout(QStringLiteral("section")), 0);
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));

        // Clamped at the ends rather than wrapping.
        wt.moveLayout(QStringLiteral("section"), -3);
        QCOMPARE(wt.indexOfLayout(QStringLiteral("section")), 0);

        // Moving the OTHER design past this one drags the selection index
        // along without changing which design is selected.
        wt.moveLayout(QStringLiteral("content"), -1);
        QCOMPARE(wt.indexOfLayout(QStringLiteral("content")), 0);
        QCOMPARE(wt.currentLayoutId(), QStringLiteral("section"));
        QCOMPARE(wt.nodes().size(), 2);
    }

    void reorderingDoesNotChangeWhichLayoutIsDefault()
    {
        WorkingTheme wt;
        wt.loadFrom(twoLayoutTokens());
        wt.moveLayout(QStringLiteral("section"), -1);
        QVERIFY(wt.layout(QStringLiteral("content")).value("default").toBool());
        QVERIFY(!wt.layout(QStringLiteral("section")).value("default").toBool());
    }
};

QTEST_MAIN(TestWorkingTheme)
#include "test_working_theme.moc"
