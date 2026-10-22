#pragma once

#include <QList>
#include <QString>
#include <QStringList>
#include <QStringView>

namespace crater::import {

// Readers for the Bible file formats Crater imports. Each one reduces a file
// to plain verse text keyed by canonical book number (1..66, and 67 up for
// the deuterocanon, see CanonicalBibleBooks.h), so the importer never deals
// with a format.
//
//   Zefania XML   <XMLBIBLE><BIBLEBOOK bnumber><CHAPTER cnumber><VERS vnumber>
//   OpenSong      <bible><b n="Genesis"><c n="1"><v n="1">, and Beblia's
//                 <bible><book number="1"><chapter number="1"><verse number="1">
//   OSIS          <osis>...<verse osisID="Gen.1.1">, as containers or as
//                 sID/eID milestones
//   USFM          \id GEN ... \c 1 ... \v 1 text, usually one file per book
//   USX           <usx><book code="GEN"/><chapter number="1"/><verse
//                 number="1"/>, one file per book
//
// Footnotes, cross references, section headings and Strong's numbers are
// dropped. The deuterocanon comes in under its own numbers. The additions a
// Catholic Bible makes inside Daniel and Esther are part of those books in
// its file, so they come in as its chapters and verses, numbered as that
// Bible numbers them. Books Crater holds under no number (the Odes, the
// Psalms of Solomon, front matter with verses) are listed in skippedBooks
// rather than imported.

struct ParsedVerse {
    int     book = 0;       // canonical 1..66, 67 up for the deuterocanon
    int     chapter = 0;
    int     verse = 0;
    int     verseEnd = 0;   // == verse unless the file combined verses ("1-2")
    QString text;
};

struct ParsedBible {
    QString format;         // "Zefania XML", "OpenSong", "OSIS", "USFM", "USX"
    QString name;           // from the file's own metadata, else its name
    QString code;           // e.g. "KJV", when the file names one
    QString language;       // e.g. "en", when the file names one
    QList<ParsedVerse> verses;
    QStringList skippedBooks;   // by name where the file used a code
    QStringList ignoredFiles;   // chosen with the book files, or in the zip, but not a Bible
    int fileCount = 0;          // Bible files read, counting those inside a zip
    QStringList otherFormats;   // the zip held this Bible in these formats too, not read
    QStringList warnings;       // read, but not all of it (a damaged file)
    // OpenSong names books in the translation's own language. Books whose
    // names said nothing were placed by their order in the file.
    bool booksByPosition = false;
    QString error;          // set when nothing could be read
};

// Reads `paths` as one Bible. XML formats are one file; USFM and USX are
// usually one file per book, and every file must then be the same format.
// A zip among them is read as the files inside it. A zip with the Bible in
// several formats is read from one of them, and one with several Bibles is
// refused.
ParsedBible parseBibleFiles(const QStringList& paths);

// Canonical book number for a USFM / USX book code ("GEN", "1CO", "TOB"),
// or 0. Psalm 151 ("PS2") is kPsalm151, which addVerse stores as Psalms 151.
int bookFromUsfmCode(QStringView code);
// Canonical book number for an OSIS book name ("Gen", "1Cor", "Tob"), or 0.
int bookFromOsisCode(QStringView code);

}  // namespace crater::import
