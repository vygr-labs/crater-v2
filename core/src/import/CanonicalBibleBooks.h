#pragma once

#include <QList>
#include <QString>
#include <QStringView>

#include <optional>

namespace crater::import {

// Canonical Bible book metadata. Each book has a stable book_number (1..66 in
// the standard Protestant canon) and a fixed testament. Names and abbreviations
// come from the SBL Handbook of Style, with common alternates handled by the
// lookup function below.
struct BibleBookMeta {
    QString name;         // canonical title-case: "Genesis", "1 Samuel", "Revelation"
    QString abbrev;       // "Gen", "1Sam", "Rev"
    int     bookNumber;   // 1..66 in canonical order
    QString testament;    // "OT" or "NT"
};

// Returns metadata for a book name. Case-insensitive. Handles common alternates:
// "psalms"/"psalm"/"ps", "1 samuel"/"1sam"/"first samuel",
// "song of solomon"/"song of songs"/"canticles", "revelation"/"revelations".
// Returns nullopt for genuinely unknown names.
std::optional<BibleBookMeta> lookupBook(QStringView nameOrAlt);

// All 66 books in canonical order.
const QList<BibleBookMeta>& allCanonicalBooks();

}  // namespace crater::import
