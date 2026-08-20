#include "crater/Version.h"

#include <QLatin1Char>
#include <QStringList>

#include <algorithm>

namespace crater {

namespace {

// "1.2.3-rc1" -> ({1, 2, 3}, "rc1").
struct Parsed
{
    QList<int> core;
    QString    suffix;
};

Parsed parseVersion(QString v)
{
    v = v.trimmed();
    if (v.startsWith(QLatin1Char('v')) || v.startsWith(QLatin1Char('V')))
        v.remove(0, 1);

    Parsed out;

    // Everything past the first '-' or '+' is the suffix. Semver draws a
    // distinction between a pre-release tag and build metadata; we do not,
    // because our releases carry neither in practice and collapsing them
    // means an unexpected '+1234' can never sort ABOVE the release it
    // annotates.
    qsizetype cut = v.indexOf(QLatin1Char('-'));
    const qsizetype plus = v.indexOf(QLatin1Char('+'));
    if (plus >= 0 && (cut < 0 || plus < cut)) cut = plus;
    if (cut >= 0) {
        out.suffix = v.mid(cut + 1);
        v.truncate(cut);
    }

    const QStringList parts = v.split(QLatin1Char('.'), Qt::SkipEmptyParts);
    for (const QString& part : parts) {
        bool      ok = false;
        const int n  = part.toInt(&ok);
        out.core.append(ok && n >= 0 ? n : 0);
    }
    return out;
}

}  // namespace

QString versionString()
{
    return QStringLiteral(CRATER_VERSION_STRING);
}

int compareVersions(const QString& a, const QString& b)
{
    const Parsed pa = parseVersion(a);
    const Parsed pb = parseVersion(b);

    // Compare over the LONGER of the two, treating absent components as 0.
    // Stopping at the shorter one would make "1.2" and "1.2.1" compare
    // equal, and an equal compare is what suppresses an upgrade.
    const qsizetype n = std::max(pa.core.size(), pb.core.size());
    for (qsizetype i = 0; i < n; ++i) {
        const int va = i < pa.core.size() ? pa.core.at(i) : 0;
        const int vb = i < pb.core.size() ? pb.core.at(i) : 0;
        if (va != vb) return va < vb ? -1 : 1;
    }

    // Identical numeric core — the pre-release suffix breaks the tie, and
    // HAVING one ranks below having none (1.0.0-rc1 < 1.0.0).
    if (pa.suffix.isEmpty() && pb.suffix.isEmpty()) return 0;
    if (pa.suffix.isEmpty()) return 1;
    if (pb.suffix.isEmpty()) return -1;

    const int cmp = QString::compare(pa.suffix, pb.suffix, Qt::CaseInsensitive);
    return cmp < 0 ? -1 : (cmp > 0 ? 1 : 0);
}

}  // namespace crater
