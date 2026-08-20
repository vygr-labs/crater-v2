// Tests for crater::sha256ForName — the SHA256SUMS.txt lookup the in-app
// updater uses to decide whether a downloaded installer may be run.
//
// Run via CTest: `ctest --test-dir <build-dir> -R checksums --output-on-failure`
//
// Why this file is thorough out of proportion to the function's size: the
// checksum file is produced by the release workflow and consumed months
// later by an installed copy of Crater, so a parsing mistake cannot be
// caught by anything closer to the change. And it fails silently — a lookup
// that matches nothing is indistinguishable from a release that published no
// checksum, and the updater responds to both by refusing to install. That is
// the safe direction, but it would quietly turn in-app updates off for
// everyone and nothing would report it.
//
// The FIRST fixture below is the literal output of the pipeline in
// .github/workflows/release.yml, so if that pipeline's format ever drifts,
// this test is where it shows up.

#include <QByteArray>
#include <QObject>
#include <QString>
#include <QTest>

#include "crater/Checksums.h"

using crater::isSha256Hex;
using crater::sha256ForName;

namespace {

// Canonical GNU coreutils text mode: two spaces, bare names. This is byte
// for byte what the release workflow writes.
const char* kCanonical =
    "f8caec96142ff739b3baefd12b31ffaee26397e993c4a94108093a7f74357b0b  Crater-0.6.2-macos.dmg\n"
    "d9414093bc25d554c82e21900cffa9e995d8bf007a9178ede9fd6b699e4cf526  Crater-0.6.2-macos.zip\n"
    "14794c91a2e494fba3e0a928b8d7c350d51ee7f6431746f4b37e2d52c77ce487  Crater-0.6.2-win64.zip\n"
    "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-Setup-0.6.2.exe\n";

const QString kExeDigest =
    QStringLiteral("4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0");

}  // namespace

class TestChecksums : public QObject
{
    Q_OBJECT

private slots:
    // ── The format the release workflow actually produces ────────────────
    void canonical_findsEachAsset()
    {
        const QByteArray sums(kCanonical);
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-0.6.2-win64.zip")),
                 QStringLiteral("14794c91a2e494fba3e0a928b8d7c350d51ee7f6431746f4b37e2d52c77ce487"));
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-0.6.2-macos.dmg")),
                 QStringLiteral("f8caec96142ff739b3baefd12b31ffaee26397e993c4a94108093a7f74357b0b"));
    }

    void canonical_unknownNameIsEmpty()
    {
        QVERIFY(sha256ForName(QByteArray(kCanonical),
                              QStringLiteral("Crater-Setup-9.9.9.exe")).isEmpty());
    }

    // Substring matches must NOT count — "Setup-0.6.2.exe" is not the asset
    // "Crater-Setup-0.6.2.exe", and accepting it would let a differently
    // named artifact satisfy the lookup.
    void canonical_matchIsExactNotSubstring()
    {
        QVERIFY(sha256ForName(QByteArray(kCanonical),
                              QStringLiteral("Setup-0.6.2.exe")).isEmpty());
        QVERIFY(sha256ForName(QByteArray(kCanonical),
                              QStringLiteral("Crater-Setup-0.6.2")).isEmpty());
    }

    void emptyNameIsEmpty()
    {
        QVERIFY(sha256ForName(QByteArray(kCanonical), QString()).isEmpty());
    }

    // ── Other shapes real tools emit ─────────────────────────────────────
    void acceptsBinaryModeMarker()
    {
        const QByteArray sums(
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0 *Crater-Setup-0.6.2.exe\n");
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    void acceptsPathsAndKeepsOnlyTheLeafName()
    {
        const QByteArray posix(
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0 *./crater-windows-0.6.2/Crater-Setup-0.6.2.exe\n");
        QCOMPARE(sha256ForName(posix, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);

        const QByteArray windows(
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  dist\\Crater-Setup-0.6.2.exe\n");
        QCOMPARE(sha256ForName(windows, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    void acceptsUppercaseDigest()
    {
        const QByteArray sums(
            "4D1359706ED5C5AAB3007DF9EF55FC9B37109382F8C867A690B2A67F098E62F0  Crater-Setup-0.6.2.exe\n");
        // Normalised to lowercase, because that is what QCryptographicHash's
        // toHex() produces on the other side of the comparison.
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    void toleratesCrLfLineEndings()
    {
        const QByteArray sums(
            "aaaa\r\n"
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-Setup-0.6.2.exe\r\n");
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    void skipsBlankAndCommentLinesAroundAGoodEntry()
    {
        const QByteArray sums(
            "\n"
            "# Crater 0.6.2 release checksums\n"
            "\n"
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-Setup-0.6.2.exe\n"
            "\n");
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    void findsAnEntryWithNoTrailingNewline()
    {
        const QByteArray sums(
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-Setup-0.6.2.exe");
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    // ── Malformed input must yield nothing, never a wrong digest ─────────
    void rejectsShortDigest()
    {
        const QByteArray sums("4d135970  Crater-Setup-0.6.2.exe\n");
        QVERIFY(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")).isEmpty());
    }

    void rejectsNonHexDigest()
    {
        const QByteArray sums(
            "zzzz59706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-Setup-0.6.2.exe\n");
        QVERIFY(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")).isEmpty());
    }

    // A digest longer than 64 chars puts the separator in the wrong place,
    // so the line is not an entry — truncating to 64 and accepting it would
    // be the dangerous reading.
    void rejectsOverlongDigest()
    {
        const QByteArray sums(
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0ff  Crater-Setup-0.6.2.exe\n");
        QVERIFY(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")).isEmpty());
    }

    void rejectsEntryWithNoFileName()
    {
        const QByteArray sums(
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  \n");
        QVERIFY(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")).isEmpty());
    }

    void emptyInputIsEmpty()
    {
        QVERIFY(sha256ForName(QByteArray(), QStringLiteral("Crater-Setup-0.6.2.exe")).isEmpty());
    }

    // A good entry after a broken one must still be found: one malformed
    // line may not take the rest of the file down with it.
    void oneBadLineDoesNotHideALaterGoodOne()
    {
        const QByteArray sums(
            "not-a-checksum-line-at-all\n"
            "zzzz59706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-0.6.2-win64.zip\n"
            "4d1359706ed5c5aab3007df9ef55fc9b37109382f8c867a690b2a67f098e62f0  Crater-Setup-0.6.2.exe\n");
        QCOMPARE(sha256ForName(sums, QStringLiteral("Crater-Setup-0.6.2.exe")), kExeDigest);
    }

    // ── isSha256Hex ──────────────────────────────────────────────────────
    void isSha256Hex_shape()
    {
        QVERIFY(isSha256Hex(kExeDigest));
        QVERIFY(!isSha256Hex(QString()));
        QVERIFY(!isSha256Hex(kExeDigest.left(63)));
        QVERIFY(!isSha256Hex(kExeDigest + QLatin1Char('a')));
        // Uppercase is a valid digest but not the normalised form this
        // predicate describes; callers lowercase first.
        QVERIFY(!isSha256Hex(kExeDigest.toUpper()));
    }
};

QTEST_GUILESS_MAIN(TestChecksums)
#include "test_checksums.moc"
