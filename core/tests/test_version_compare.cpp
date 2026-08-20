// Tests for crater::compareVersions / isNewerVersion — the ordering the
// in-app updater uses to decide whether a GitHub release is an upgrade.
//
// Run via CTest: `ctest --test-dir <build-dir> -R version_compare --output-on-failure`
// Or directly:   `./test_version_compare` from the build output directory.
//
// Coverage philosophy: this function is small but it is the ONLY thing
// standing between a published release and a machine that never offers it,
// and its failure mode is silent (no crash, no log line — the updater just
// keeps reporting "up to date" forever). So the cases below deliberately
// over-cover the boring parts: double-digit components, missing components,
// tag prefixes, and every shape of junk the network can hand us.

#include <QObject>
#include <QString>
#include <QTest>

#include "crater/Version.h"

using crater::compareVersions;
using crater::isNewerVersion;
using crater::isVersionTag;

class TestVersionCompare : public QObject
{
    Q_OBJECT

private slots:
    // ── Equality ────────────────────────────────────────────────────────
    void equal_identical()
    {
        QCOMPARE(compareVersions(QStringLiteral("1.2.3"),
                                 QStringLiteral("1.2.3")), 0);
    }

    // The release workflow tags "v0.6.1" while CMake's project() carries
    // "0.6.1". These must compare equal or every user is permanently one
    // phantom update behind.
    void equal_ignoresTagPrefix()
    {
        QCOMPARE(compareVersions(QStringLiteral("v0.6.1"),
                                 QStringLiteral("0.6.1")), 0);
        QCOMPARE(compareVersions(QStringLiteral("V0.6.1"),
                                 QStringLiteral("0.6.1")), 0);
    }

    void equal_missingComponentsReadAsZero()
    {
        QCOMPARE(compareVersions(QStringLiteral("1.2"),
                                 QStringLiteral("1.2.0")), 0);
        QCOMPARE(compareVersions(QStringLiteral("1"),
                                 QStringLiteral("1.0.0")), 0);
    }

    void equal_toleratesSurroundingWhitespace()
    {
        QCOMPARE(compareVersions(QStringLiteral("  1.2.3  "),
                                 QStringLiteral("1.2.3")), 0);
    }

    // ── Numeric ordering ────────────────────────────────────────────────
    void ordering_patch()
    {
        QVERIFY(compareVersions(QStringLiteral("1.2.4"),
                                QStringLiteral("1.2.3")) > 0);
        QVERIFY(compareVersions(QStringLiteral("1.2.3"),
                                QStringLiteral("1.2.4")) < 0);
    }

    void ordering_minorOutranksPatch()
    {
        QVERIFY(compareVersions(QStringLiteral("1.3.0"),
                                QStringLiteral("1.2.99")) > 0);
    }

    void ordering_majorOutranksMinor()
    {
        QVERIFY(compareVersions(QStringLiteral("2.0.0"),
                                QStringLiteral("1.99.99")) > 0);
    }

    // The reason this function exists at all. A lexicographic compare puts
    // "0.10.0" below "0.9.0" because '1' < '9', which silently freezes the
    // updater the first time a component reaches double digits.
    void ordering_doubleDigitComponentsAreNumeric()
    {
        QVERIFY(compareVersions(QStringLiteral("0.10.0"),
                                QStringLiteral("0.9.0")) > 0);
        QVERIFY(compareVersions(QStringLiteral("1.0.10"),
                                QStringLiteral("1.0.9")) > 0);
        QVERIFY(compareVersions(QStringLiteral("10.0.0"),
                                QStringLiteral("9.99.99")) > 0);
    }

    void ordering_extraComponentIsAnUpgrade()
    {
        QVERIFY(compareVersions(QStringLiteral("1.2.3.1"),
                                QStringLiteral("1.2.3")) > 0);
    }

    // ── Pre-release suffixes ────────────────────────────────────────────
    void prerelease_ranksBelowTheSameRelease()
    {
        QVERIFY(compareVersions(QStringLiteral("1.0.0-rc1"),
                                QStringLiteral("1.0.0")) < 0);
        QVERIFY(compareVersions(QStringLiteral("1.0.0"),
                                QStringLiteral("1.0.0-rc1")) > 0);
    }

    void prerelease_stillLosesToAHigherCore()
    {
        QVERIFY(compareVersions(QStringLiteral("1.0.1-rc1"),
                                QStringLiteral("1.0.0")) > 0);
    }

    void prerelease_comparesAlphabeticallyOnTheSameCore()
    {
        QVERIFY(compareVersions(QStringLiteral("1.0.0-beta"),
                                QStringLiteral("1.0.0-alpha")) > 0);
        QVERIFY(compareVersions(QStringLiteral("1.0.0-rc2"),
                                QStringLiteral("1.0.0-rc1")) > 0);
    }

    // Build metadata is folded into the suffix rather than ignored, so it
    // can never sort ABOVE the plain release it annotates.
    void prerelease_buildMetadataDoesNotOutrankTheRelease()
    {
        QVERIFY(compareVersions(QStringLiteral("1.0.0+build7"),
                                QStringLiteral("1.0.0")) < 0);
    }

    // ── Junk tolerance ──────────────────────────────────────────────────
    // Every one of these arrives over the network. None may be mistaken for
    // an upgrade over a real installed version.
    void junk_emptyIsLowest()
    {
        QVERIFY(compareVersions(QString(), QStringLiteral("0.0.1")) < 0);
        QCOMPARE(compareVersions(QString(), QStringLiteral("0.0.0")), 0);
    }

    void junk_nonNumericComponentsReadAsZero()
    {
        QCOMPARE(compareVersions(QStringLiteral("1.x.3"),
                                 QStringLiteral("1.0.3")), 0);
        QVERIFY(compareVersions(QStringLiteral("nightly"),
                                QStringLiteral("0.6.1")) < 0);
    }

    // A stray '-' mid-string is read as the pre-release separator, so
    // "1.-5.0" parses as core {1} with the suffix "5.0" and lands just under
    // 1.0.0. The exact placement is not the point and is not asserted; what
    // IS asserted is the invariant every junk case shares — a malformed
    // version never outranks a real one, so it can never trigger an update.
    void junk_negativeComponentDoesNotOutrank()
    {
        QVERIFY(compareVersions(QStringLiteral("1.-5.0"),
                                QStringLiteral("1.0.0")) <= 0);
        QVERIFY(compareVersions(QStringLiteral("1.0.-1"),
                                QStringLiteral("1.0.0")) <= 0);
    }

    // ── isNewerVersion wrapper ──────────────────────────────────────────
    void isNewer_onlyStrictlyGreater()
    {
        QVERIFY(isNewerVersion(QStringLiteral("v0.7.0"),
                               QStringLiteral("0.6.1")));
        QVERIFY(!isNewerVersion(QStringLiteral("v0.6.1"),
                                QStringLiteral("0.6.1")));
        QVERIFY(!isNewerVersion(QStringLiteral("v0.6.0"),
                                QStringLiteral("0.6.1")));
    }

    // A release whose tag we cannot parse must never trigger a download.
    void isNewer_garbledTagIsNotAnUpgrade()
    {
        QVERIFY(!isNewerVersion(QStringLiteral("latest"),
                                QStringLiteral("0.6.1")));
        QVERIFY(!isNewerVersion(QString(), QStringLiteral("0.6.1")));
    }

    // ── isVersionTag ────────────────────────────────────────────────────
    // The filter that decides which GitHub releases are Crater builds at
    // all. Getting this wrong does not produce a bad update — junk sorts
    // low — it produces NO updates, permanently and silently.
    void isVersionTag_acceptsOurReleaseTags()
    {
        QVERIFY(isVersionTag(QStringLiteral("v0.6.1")));
        QVERIFY(isVersionTag(QStringLiteral("v1.0.0")));
        QVERIFY(isVersionTag(QStringLiteral("0.6.1")));     // no 'v' is fine
        QVERIFY(isVersionTag(QStringLiteral("v10.20.30")));
        QVERIFY(isVersionTag(QStringLiteral(" v0.6.1 ")));  // whitespace tolerated
    }

    void isVersionTag_acceptsAPreReleaseSuffix()
    {
        QVERIFY(isVersionTag(QStringLiteral("v1.0.0-rc1")));
        QVERIFY(isVersionTag(QStringLiteral("v1.0.0+build7")));
    }

    // The case this predicate was written for. vygr-labs/crater-v2 already
    // publishes `data-v1` for the bundled Bible / Strong's databases, and a
    // future `data-v2` would otherwise become GitHub's "latest release".
    void isVersionTag_rejectsTheDataBundleTags()
    {
        QVERIFY(!isVersionTag(QStringLiteral("data-v1")));
        QVERIFY(!isVersionTag(QStringLiteral("data-v2")));
        QVERIFY(!isVersionTag(QStringLiteral("bibles-2026-05")));
    }

    void isVersionTag_rejectsOtherNonReleases()
    {
        QVERIFY(!isVersionTag(QString()));
        QVERIFY(!isVersionTag(QStringLiteral("latest")));
        QVERIFY(!isVersionTag(QStringLiteral("nightly")));
        QVERIFY(!isVersionTag(QStringLiteral("v")));
        QVERIFY(!isVersionTag(QStringLiteral("release-1.0")));
    }

    void isVersionTag_rejectsMalformedNumericCores()
    {
        QVERIFY(!isVersionTag(QStringLiteral("v1..2")));
        QVERIFY(!isVersionTag(QStringLiteral("v1.")));
        QVERIFY(!isVersionTag(QStringLiteral("v.1")));
        QVERIFY(!isVersionTag(QStringLiteral("v1.x.3")));
    }

    // Whatever isVersionTag accepts, compareVersions must be able to order
    // sensibly — the two are used together and a gap between them would let
    // a tag through that then compares as garbage.
    void isVersionTag_acceptedTagsOrderCorrectly()
    {
        QVERIFY(isVersionTag(QStringLiteral("v0.9.0")));
        QVERIFY(isVersionTag(QStringLiteral("v0.10.0")));
        QVERIFY(compareVersions(QStringLiteral("v0.10.0"),
                                QStringLiteral("v0.9.0")) > 0);
    }
};

QTEST_GUILESS_MAIN(TestVersionCompare)
#include "test_version_compare.moc"
