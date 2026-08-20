#include "crater/Checksums.h"

#include <QList>

namespace crater {

bool isSha256Hex(const QString& s)
{
    if (s.size() != 64) return false;
    for (const QChar c : s) {
        const bool digit = c >= QLatin1Char('0') && c <= QLatin1Char('9');
        const bool alpha = c >= QLatin1Char('a') && c <= QLatin1Char('f');
        if (!digit && !alpha) return false;
    }
    return true;
}

QString sha256ForName(const QByteArray& sums, const QString& name)
{
    if (name.isEmpty()) return QString();

    const QList<QByteArray> lines = sums.split('\n');
    for (const QByteArray& raw : lines) {
        // Latin-1 rather than UTF-8: a checksum file is hex plus ASCII file
        // names, and decoding it as UTF-8 would let a malformed byte
        // sequence turn into a replacement character mid-name. Latin-1 never
        // fails, so a bad byte can only ever cause a name to not match.
        const QString line = QString::fromLatin1(raw).trimmed();

        // The digest is fixed-width, so the separator must be at index 64.
        // Anything else (a comment, a blank line, a truncated entry) is not
        // an entry and is skipped rather than guessed at.
        if (line.indexOf(QLatin1Char(' ')) != 64) continue;

        const QString digest = line.left(64).toLower();
        if (!isSha256Hex(digest)) continue;

        QString file = line.mid(64).trimmed();
        if (file.startsWith(QLatin1Char('*'))) file.remove(0, 1);   // binary-mode flag
        if (file.isEmpty()) continue;

        // Compare on the leaf name only, so a sums file generated from a
        // directory walk still matches a bare asset name. Both separators are
        // stripped because the file may have been produced on either OS.
        file = file.section(QLatin1Char('/'), -1).section(QLatin1Char('\\'), -1);

        if (file == name) return digest;
    }
    return QString();
}

}  // namespace crater
