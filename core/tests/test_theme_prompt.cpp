// Tests for the "design with AI" round trip — crater/ThemePrompt.h and
// ThemeService::parseThemeJsonText.
//
// Two halves of one loop, and both fail quietly if they regress:
//
//   1. The PROMPT is a second statement of the theme schema, aimed at a model
//      that has never seen qt/docs/theme-schema.md. Drop a rule from it and
//      nothing breaks here — it breaks in a chat window the user then has to
//      argue with. So the cases below pin the parts a wrong answer hinges on:
//      the kind is stated and legal, only that kind's linkages are offered,
//      and the layout vocabulary appears for exactly the kind that can use it.
//
//   2. The PARSE is what a chat reply actually looks like, which is rarely a
//      bare JSON document. Fences, a preamble and a missing envelope are the
//      three shapes that show up constantly, and rejecting them reads to the
//      user as "the AI got it wrong" when the AI got it right.
//
// Run via CTest: `ctest --test-dir <build-dir> -R theme_prompt --output-on-failure`

#include <QDir>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QTest>
#include <QVariantList>
#include <QVariantMap>

#include "crater/Bootstrap.h"
#include "crater/ThemePrompt.h"
#include "crater/ThemeService.h"

using crater::ThemeService;
using crater::prompt::designPrompt;

namespace {

// A minimal but VALID v3 theme, so a parse failure in a test can only be the
// text handling under test and never the token content.
QString validThemeJson(const QString& name = QStringLiteral("Aurora"),
                       const QString& kind = QStringLiteral("presentation"))
{
    return QStringLiteral(R"({
  "name": "%1",
  "kind": "%2",
  "tokens": {
    "version": 3,
    "canvas": { "width": 1920, "height": 1080 },
    "layouts": [
      { "id": "content", "name": "Title + content", "default": true,
        "nodes": [
          { "id": "bg", "kind": "container",
            "style": { "x": 0, "y": 0, "width": 100, "height": 100, "z": 0 },
            "data": {} },
          { "id": "title", "kind": "text",
            "style": { "x": 8, "y": 40, "width": 84, "height": 20, "z": 10,
                       "color": "#ffffff" },
            "data": { "linkage": "presentationTitle" } }
        ] }
    ]
  }
})").arg(name, kind);
}

QString bareTokensJson()
{
    return QStringLiteral(R"({
  "version": 3,
  "canvas": { "width": 1920, "height": 1080 },
  "layouts": [
    { "id": "content", "name": "Title + content", "default": true,
      "nodes": [
        { "id": "title", "kind": "text",
          "style": { "x": 8, "y": 40, "width": 84, "height": 20, "z": 10,
                     "color": "#ffffff" },
          "data": { "linkage": "presentationTitle" } }
      ] }
  ]
})");
}

}  // namespace

class TestThemePrompt : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
        crater::runAllMigrations();
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    // ── The prompt ──────────────────────────────────────────────────────

    // The envelope's "kind" is validated on the way back in, so a prompt that
    // fails to state it hands the model a field it has to guess.
    void statesTheKindInTheOutputEnvelope()
    {
        QVERIFY(designPrompt(QStringLiteral("song"))
                    .contains(QStringLiteral("\"kind\": \"song\"")));
        QVERIFY(designPrompt(QStringLiteral("scripture"))
                    .contains(QStringLiteral("\"kind\": \"scripture\"")));
        QVERIFY(designPrompt(QStringLiteral("presentation"))
                    .contains(QStringLiteral("\"kind\": \"presentation\"")));
    }

    // An unknown kind must still produce a LEGAL envelope. Emitting the bad
    // kind verbatim would give the model a value the importer rejects, and
    // the rejection would name a field the user never typed.
    void unknownKindFallsBackToALegalOne()
    {
        const QString p = designPrompt(QStringLiteral("interpretive-dance"));
        QVERIFY(!p.contains(QStringLiteral("interpretive-dance")));
        QVERIFY(p.contains(QStringLiteral("\"kind\": \"presentation\"")));
    }

    // Offering a linkage the kind cannot render produces a theme with dead
    // text boxes in it, and the validator has no reason to complain because
    // linkage is checked globally.
    void offersOnlyTheLinkagesTheKindCanRender()
    {
        const QString song = designPrompt(QStringLiteral("song"));
        QVERIFY(song.contains(QStringLiteral("\"lyric\"")));
        QVERIFY(!song.contains(QStringLiteral("presentationBody")));
        QVERIFY(!song.contains(QStringLiteral("scriptureText")));

        const QString scripture = designPrompt(QStringLiteral("scripture"));
        QVERIFY(scripture.contains(QStringLiteral("\"scriptureText\"")));
        QVERIFY(!scripture.contains(QStringLiteral("\"lyric\"")));

        const QString pres = designPrompt(QStringLiteral("presentation"));
        QVERIFY(pres.contains(QStringLiteral("presentationBodyRight")));
        QVERIFY(pres.contains(QStringLiteral("presentationImage")));
        QVERIFY(!pres.contains(QStringLiteral("\"lyric\"")));
    }

    // Only a presentation slide can select a design. Handing the other kinds
    // the layout vocabulary would invite a model to author designs that
    // nothing in the app can ever reach.
    void onlyPresentationGetsTheLayoutVocabulary()
    {
        const QString pres = designPrompt(QStringLiteral("presentation"));
        QVERIFY(pres.contains(QStringLiteral("\"twoColumn\"")));
        QVERIFY(pres.contains(QStringLiteral("\"section\"")));

        const QString song = designPrompt(QStringLiteral("song"));
        QVERIFY(!song.contains(QStringLiteral("\"twoColumn\"")));
        // ...but it must still be told to emit the layouts wrapper, because
        // that is what v3 validation requires of every theme.
        QVERIFY(song.contains(QStringLiteral("\"layouts\"")));
        QVERIFY(song.contains(QStringLiteral("renders ONE design")));
    }

    void carriesTheUsersBriefVerbatim()
    {
        const QString brief =
            QStringLiteral("Deep navy, gold rule, Cambria. For a carol service.");
        QVERIFY(designPrompt(QStringLiteral("song"), brief).contains(brief));
    }

    // The empty brief is the "surprise me" path, not an empty section. A
    // model handed a blank heading asks a clarifying question instead of
    // designing, which is the one thing this feature cannot afford.
    void anEmptyBriefStillAsksForADesign()
    {
        const QString p = designPrompt(QStringLiteral("song"), QString());
        QVERIFY(p.contains(QStringLiteral("## The brief")));
        QVERIFY(p.contains(QStringLiteral("I have not specified a look")));

        // Whitespace is the same case as empty.
        QCOMPARE(designPrompt(QStringLiteral("song"), QStringLiteral("   \n  ")), p);
    }

    void startFromEmbedsTheCurrentThemeAndIsOtherwiseAbsent()
    {
        QVariantMap canvas;
        canvas[QStringLiteral("width")]  = 1920;
        canvas[QStringLiteral("height")] = 1080;
        QVariantMap tokens;
        tokens[QStringLiteral("version")] = 3;
        tokens[QStringLiteral("canvas")]  = canvas;

        const QString with = designPrompt(QStringLiteral("song"), QString(), tokens);
        QVERIFY(with.contains(QStringLiteral("## The design I have now")));
        QVERIFY(with.contains(QStringLiteral("\"width\": 1920")));

        const QString without = designPrompt(QStringLiteral("song"));
        QVERIFY(!without.contains(QStringLiteral("## The design I have now")));
    }

    // The prompt is pasted into a browser text box. Smart quotes and dashes
    // survive that trip unreliably, and a mangled quote inside the JSON
    // skeleton is a rejected reply the user cannot see the cause of.
    void isPlainAscii()
    {
        const QStringList kinds{ QStringLiteral("song"),
                                 QStringLiteral("scripture"),
                                 QStringLiteral("presentation") };
        for (const QString& kind : kinds) {
            const QString p = designPrompt(kind);
            for (int i = 0; i < p.size(); ++i) {
                if (p.at(i).unicode() > 127) {
                    QFAIL(qPrintable(
                        QStringLiteral("non-ASCII 0x%1 at %2 in the %3 prompt: ...%4...")
                            .arg(QString::number(p.at(i).unicode(), 16))
                            .arg(i).arg(kind)
                            .arg(p.mid(qMax(0, i - 40), 80))));
                }
            }
        }
    }

    // ── Reading the reply back ──────────────────────────────────────────

    void acceptsAPlainEnvelope()
    {
        ThemeService ts;
        const QVariantMap r = ts.parseThemeJsonText(validThemeJson());
        QVERIFY2(r.value(QStringLiteral("ok")).toBool(),
                 qPrintable(r.value(QStringLiteral("error")).toString()));
        QCOMPARE(r.value(QStringLiteral("name")).toString(), QStringLiteral("Aurora"));
        QCOMPARE(r.value(QStringLiteral("kind")).toString(), QStringLiteral("presentation"));
        QVERIFY(!r.value(QStringLiteral("tokens")).toMap().isEmpty());
    }

    // What a chat window actually hands you.
    void stripsMarkdownFences()
    {
        ThemeService ts;
        const QString fenced = QStringLiteral("```json\n") + validThemeJson()
                             + QStringLiteral("\n```");
        const QVariantMap r = ts.parseThemeJsonText(fenced);
        QVERIFY2(r.value(QStringLiteral("ok")).toBool(),
                 qPrintable(r.value(QStringLiteral("error")).toString()));
        QCOMPARE(r.value(QStringLiteral("name")).toString(), QStringLiteral("Aurora"));
    }

    void stripsChatterAroundTheJson()
    {
        ThemeService ts;
        const QString chatty =
            QStringLiteral("Here is your theme! I went for a deep navy.\n\n")
            + validThemeJson()
            + QStringLiteral("\n\nLet me know if you want it warmer.");
        const QVariantMap r = ts.parseThemeJsonText(chatty);
        QVERIFY2(r.value(QStringLiteral("ok")).toBool(),
                 qPrintable(r.value(QStringLiteral("error")).toString()));
        QCOMPARE(r.value(QStringLiteral("name")).toString(), QStringLiteral("Aurora"));
    }

    // A model asked for a theme routinely returns the tokens object alone.
    // That is unambiguous, so it is recognised rather than refused — but the
    // name and kind must come back EMPTY rather than invented, because the
    // caller decides what to do about a theme that did not name itself.
    void acceptsABareTokensObject()
    {
        ThemeService ts;
        const QVariantMap r = ts.parseThemeJsonText(bareTokensJson());
        QVERIFY2(r.value(QStringLiteral("ok")).toBool(),
                 qPrintable(r.value(QStringLiteral("error")).toString()));
        QCOMPARE(r.value(QStringLiteral("name")).toString(), QString());
        QCOMPARE(r.value(QStringLiteral("kind")).toString(), QString());
        QVERIFY(!r.value(QStringLiteral("tokens")).toMap().isEmpty());
    }

    void keepsTheKindTheReplyDeclared()
    {
        ThemeService ts;
        const QVariantMap r = ts.parseThemeJsonText(
            validThemeJson(QStringLiteral("Strap"), QStringLiteral("song")));
        QVERIFY(r.value(QStringLiteral("ok")).toBool());
        // Reported, not corrected. The editor warns on a mismatch; silently
        // rewriting it would hide the fact that the model ignored the brief.
        QCOMPARE(r.value(QStringLiteral("kind")).toString(), QStringLiteral("song"));
    }

    // The paste path runs the same validator Save runs, so anything it
    // accepts is already known to survive the trip to the database.
    void reportsValidationErrorsInsteadOfAccepting()
    {
        ThemeService ts;
        const QString bad = QStringLiteral(R"({
  "name": "Broken", "kind": "presentation",
  "tokens": { "version": 3, "canvas": { "width": 1920, "height": 1080 },
              "layouts": [ { "id": "content", "name": "C", "nodes": [] } ] }
})");
        const QVariantMap r = ts.parseThemeJsonText(bad);
        QVERIFY(!r.value(QStringLiteral("ok")).toBool());
        QVERIFY(!r.value(QStringLiteral("error")).toString().isEmpty());
    }

    void rejectsTextWithNoJsonInIt()
    {
        ThemeService ts;
        const QVariantMap r = ts.parseThemeJsonText(
            QStringLiteral("I'd love to help! What sort of look are you after?"));
        QVERIFY(!r.value(QStringLiteral("ok")).toBool());
        QVERIFY(!r.value(QStringLiteral("error")).toString().isEmpty());
    }

    void rejectsEmptyText()
    {
        ThemeService ts;
        QVERIFY(!ts.parseThemeJsonText(QString())
                    .value(QStringLiteral("ok")).toBool());
    }

    // The prompt promises v3 with a layouts array. If the two ever disagree
    // about the envelope, every reply a user pastes fails validation — so
    // pin the skeleton the prompt hands out against the validator itself.
    void thePromptsOwnSkeletonValidates()
    {
        ThemeService ts;
        const QVariantMap r = ts.parseThemeJsonText(validThemeJson());
        QVERIFY(r.value(QStringLiteral("ok")).toBool());

        const QString p = designPrompt(QStringLiteral("presentation"));
        QVERIFY(p.contains(QStringLiteral("\"version\": 3")));
        QVERIFY(p.contains(QStringLiteral("\"canvas\": { \"width\": 1920, \"height\": 1080 }")));
        QVERIFY(p.contains(QStringLiteral("\"default\": true")));
    }

private:
    QString m_dataDir;
};

// ThemeService reaches QFontDatabase through its validation path, and that
// needs a QGuiApplication, so this can't be QTEST_GUILESS_MAIN.
int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestThemePrompt tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_theme_prompt.moc"
