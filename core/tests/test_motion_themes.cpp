// Theme motion (data.motion): the built-in lower thirds V014 seeds, and the
// validator that guards motion in imported and saved themes.
//
// V014 only adds themes. A fresh install and an upgrade both keep the
// scripture and song defaults they would have had without it, because a
// transparent lower third is the wrong first thing on a projector.

#include <QDir>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QObject>
#include <QStandardPaths>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/ThemeService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

namespace {

const QString kSlate = QStringLiteral("Slate Lower Third");

// A one-node theme carrying `motion` on its node, as tokens.
QVariantMap themeWithMotion(const QString& motionJson)
{
    const QString json = QStringLiteral(R"({
        "version": 3, "canvas": {"width": 1920, "height": 1080},
        "layouts": [{"id": "content", "name": "Content", "default": true, "nodes": [
            {"id": "bar", "kind": "container",
             "style": {"x": 0, "y": 80, "width": 100, "height": 20, "backgroundColor": "#000000"},
             "data": {"motion": %1}}
        ]}]})").arg(motionJson);
    return QJsonDocument::fromJson(json.toUtf8()).toVariant().toMap();
}

}  // namespace

class TestMotionThemes : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    void freshDataDir()
    {
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
    }

    static qint64 builtinId(const QString& kind, const QString& name)
    {
        crater::db::Connection conn(crater::db::DbPaths::appDbPath());
        auto q = conn.prepare(u"SELECT id FROM themes WHERE kind = ? AND is_builtin = 1 AND name = ?");
        q.bind(1, kind);
        q.bind(2, name);
        return q.step() ? q.columnInt64(0) : 0;
    }

    QStringList errorsFor(const QString& motionJson)
    {
        crater::ThemeService themes;
        return themes.validateTokens(themeWithMotion(motionJson));
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    // ── V014 ───────────────────────────────────────────────────────────

    void freshInstallSeedsSlateWithoutChangingDefaults()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        for (const QString kind : {QStringLiteral("scripture"), QStringLiteral("song")}) {
            const crater::Theme t = themes.theme(builtinId(kind, kSlate));
            QVERIFY2(t.id != 0, qPrintable(kind));
            QVERIFY(t.isBuiltin);
            QCOMPARE(t.kind, kind);
            QCOMPARE(themes.validateTokens(t.tokens), QStringList());
            QCOMPARE(themes.defaultFor(kind).name, QStringLiteral("Plum & Rose"));
        }
    }

    void slateCarriesMotionOnEveryNode()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        for (const QString kind : {QStringLiteral("scripture"), QStringLiteral("song")}) {
            const crater::Theme t = themes.theme(builtinId(kind, kSlate));
            const QVariantList nodes = themes.layoutNodes(t.tokens, QString());
            QVERIFY(!nodes.isEmpty());
            QStringList linkages;
            for (const QVariant& v : nodes) {
                const QVariantMap data = v.toMap().value(QStringLiteral("data")).toMap();
                const QVariantMap motion = data.value(QStringLiteral("motion")).toMap();
                QVERIFY2(motion.contains(QStringLiteral("in")), qPrintable(v.toMap().value("id").toString()));
                QVERIFY2(motion.contains(QStringLiteral("out")), qPrintable(v.toMap().value("id").toString()));
                linkages << data.value(QStringLiteral("linkage")).toString();
            }
            // No background node: the frame outside the card stays clear.
            for (const QVariant& v : nodes)
                QVERIFY(v.toMap().value(QStringLiteral("id")).toString() != QLatin1String("bg"));
            QVERIFY(linkages.contains(kind == QLatin1String("song") ? QStringLiteral("lyric")
                                                                    : QStringLiteral("scriptureText")));
            // The song card owns the credits so the projector's own credits
            // line doesn't draw across it.
            if (kind == QLatin1String("song"))
                QVERIFY(linkages.contains(QStringLiteral("songCredits")));
        }
    }

    void upgradeSeedsSlateAndKeepsTheDefault()
    {
        // An install that last ran V013 a while ago and never chose a
        // default: it's implicitly on Classic Dark and must stay there.
        freshDataDir();
        crater::runAllMigrations();
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.exec(u"DELETE FROM kv WHERE key IN ('default_song_theme_id', 'default_scripture_theme_id')");
            conn.exec(u"DELETE FROM themes WHERE name = 'Slate Lower Third'");
            conn.exec(u"UPDATE themes SET created_at = created_at - 86400000");
            conn.setUserVersion(13);
        }
        crater::runAllMigrations();
        QVERIFY(builtinId(QStringLiteral("scripture"), kSlate) != 0);
        QVERIFY(builtinId(QStringLiteral("song"), kSlate) != 0);
        crater::ThemeService themes;
        QCOMPARE(themes.defaultFor(QStringLiteral("scripture")).name, QStringLiteral("Classic Dark"));
        QCOMPARE(themes.defaultFor(QStringLiteral("song")).name, QStringLiteral("Classic Dark"));
    }

    void rerunningDoesNotDuplicate()
    {
        freshDataDir();
        crater::runAllMigrations();
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.setUserVersion(13);
        }
        crater::runAllMigrations();
        crater::db::Connection conn(crater::db::DbPaths::appDbPath());
        auto q = conn.prepare(u"SELECT COUNT(*) FROM themes WHERE name = 'Slate Lower Third'");
        QVERIFY(q.step());
        QCOMPARE(q.columnInt(0), 2);
    }

    // ── Validator ──────────────────────────────────────────────────────

    void acceptsMotion_data()
    {
        QTest::addColumn<QString>("motion");
        QTest::newRow("null") << "null";
        QTest::newRow("empty") << "{}";
        QTest::newRow("null phases") << R"({"in": null, "out": null})";
        QTest::newRow("fade") << R"({"in": {"type": "fade"}})";
        QTest::newRow("slide") << R"({"in": {"type": "slide", "edge": "bottom", "distance": 28,
                                     "duration": 500, "delay": 0, "easing": "smooth"}})";
        QTest::newRow("wipe right") << R"({"in": {"type": "wipe", "edge": "right"}})";
        QTest::newRow("grow center") << R"({"out": {"type": "grow", "edge": "center", "easing": "in"}})";
        QTest::newRow("css curve") << R"({"in": {"type": "fade", "easing": [0.2, 0.8, 0.2, 1]}})";
        QTest::newRow("overshoot curve") << R"({"in": {"type": "fade", "easing": [0.3, -0.5, 0.7, 1.6]}})";
        QTest::newRow("swap") << R"({"swap": {"out": 160, "in": 260}})";
    }
    void acceptsMotion()
    {
        QFETCH(QString, motion);
        QCOMPARE(errorsFor(motion), QStringList());
    }

    void rejectsMotion_data()
    {
        QTest::addColumn<QString>("motion");
        QTest::addColumn<QString>("error");
        QTest::newRow("not an object") << R"("rise")"
            << "nodes[0].data.motion must be an object";
        QTest::newRow("phase not an object") << R"({"in": "fade"})"
            << "nodes[0].data.motion.in must be an object";
        QTest::newRow("unknown type") << R"({"in": {"type": "rise"}})"
            << "nodes[0].data.motion.in.type must be fade|slide|wipe|grow";
        QTest::newRow("missing type") << R"({"out": {"duration": 300}})"
            << "nodes[0].data.motion.out.type must be fade|slide|wipe|grow";
        QTest::newRow("bad edge") << R"({"in": {"type": "slide", "edge": "up"}})"
            << "nodes[0].data.motion.in.edge must be bottom|top|left|right";
        QTest::newRow("center only grows") << R"({"in": {"type": "wipe", "edge": "center"}})"
            << "nodes[0].data.motion.in.edge must be bottom|top|left|right";
        QTest::newRow("bad grow edge") << R"({"in": {"type": "grow", "edge": "middle"}})"
            << "nodes[0].data.motion.in.edge must be bottom|top|left|right|center";
        QTest::newRow("long duration") << R"({"in": {"type": "fade", "duration": 6000}})"
            << "nodes[0].data.motion.in.duration must be 0..5000";
        QTest::newRow("negative delay") << R"({"out": {"type": "fade", "delay": -10}})"
            << "nodes[0].data.motion.out.delay must be 0..5000";
        QTest::newRow("text distance") << R"({"in": {"type": "slide", "distance": "far"}})"
            << "nodes[0].data.motion.in.distance must be 0..2000";
        QTest::newRow("unknown easing") << R"({"in": {"type": "fade", "easing": "bounce"}})"
            << "nodes[0].data.motion.in.easing must be smooth|out|in|inOut|linear|back "
               "or [x1, y1, x2, y2] with x in 0..1";
        QTest::newRow("curve x out of range") << R"({"in": {"type": "fade", "easing": [1.2, 0, 0.5, 1]}})"
            << "nodes[0].data.motion.in.easing must be smooth|out|in|inOut|linear|back "
               "or [x1, y1, x2, y2] with x in 0..1";
        QTest::newRow("short curve") << R"({"in": {"type": "fade", "easing": [0.2, 0.8, 0.2]}})"
            << "nodes[0].data.motion.in.easing must be smooth|out|in|inOut|linear|back "
               "or [x1, y1, x2, y2] with x in 0..1";
        QTest::newRow("swap not an object") << R"({"swap": 200})"
            << "nodes[0].data.motion.swap must be an object";
        QTest::newRow("long swap") << R"({"swap": {"in": 2500}})"
            << "nodes[0].data.motion.swap.in must be 0..2000";
    }
    void rejectsMotion()
    {
        QFETCH(QString, motion);
        QFETCH(QString, error);
        // A v3 theme names the layout in front of each node error.
        const QStringList errs = errorsFor(motion);
        QVERIFY2(errs.contains(QStringLiteral("layouts[0] \"Content\": ") + error),
                 qPrintable(errs.join(QStringLiteral(" / "))));
    }
};

// ThemeService touches QFontDatabase, which needs a QGuiApplication.
int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestMotionThemes tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_motion_themes.moc"
