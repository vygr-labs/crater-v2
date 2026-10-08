// Tests for crater::HelpLinks, the addresses behind the Help section, the
// F1 dialog's video link and the empty schedule's Getting started link.
//
// A typo or a blank here ships as a button that opens nothing, and nobody
// notices until an operator presses it, so every address is checked.

#include <QObject>
#include <QTest>
#include <QUrl>

#include "crater/HelpLinks.h"

using crater::HelpLinks;

namespace {

void checkUrl(const QString& s, const char* what)
{
    const QUrl url(s, QUrl::StrictMode);
    QVERIFY2(url.isValid() && url.scheme() == QLatin1String("https")
                 && !url.host().isEmpty(),
             qPrintable(QStringLiteral("%1 is not an https address: '%2'")
                            .arg(QLatin1String(what), s)));
}

}  // namespace

class TestHelpLinks : public QObject
{
    Q_OBJECT

private slots:
    void siteAddresses()
    {
        HelpLinks links;
        checkUrl(links.channel(), "channel");
        checkUrl(links.docs(),    "docs");
        checkUrl(links.website(), "website");
    }

    // HelpSection.qml, ShortcutsDialog.qml and SchedulePanel.qml ask for
    // these ids by name, so dropping or renaming one breaks a link there.
    void playlistIds()
    {
        HelpLinks links;
        QCOMPARE(links.playlistIds(), QStringList({
            QStringLiteral("getting-started"), QStringLiteral("scripture"),
            QStringLiteral("songs"),           QStringLiteral("media"),
            QStringLiteral("planning"),        QStringLiteral("themes"),
            QStringLiteral("screens"),         QStringLiteral("settings"),
            QStringLiteral("shortcuts") }));
    }

    void everyPlaylistHasAnAddress()
    {
        HelpLinks links;
        QStringList seen;
        for (const QString& id : links.playlistIds()) {
            const QString url = links.playlist(id);
            checkUrl(url, qPrintable(id));
            QVERIFY2(QUrl(url).query().contains(QLatin1String("list=")),
                     qPrintable(id + QLatin1String(" is not a playlist link")));
            QVERIFY2(!seen.contains(url),
                     qPrintable(id + QLatin1String(" repeats another playlist")));
            seen.append(url);
        }
    }

    void unknownIdIsEmpty()
    {
        HelpLinks links;
        QVERIFY(links.playlist(QStringLiteral("nope")).isEmpty());
    }
};

QTEST_GUILESS_MAIN(TestHelpLinks)
#include "test_help_links.moc"
