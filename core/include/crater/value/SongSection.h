#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QtQmlIntegration>

namespace crater {

// One section of a song — Verse 1, Chorus, Bridge, etc.
//
// `lines` holds the lyric body, one entry per visual line. Each entry is a
// DSL string in the lyric-formatting grammar defined by crater::lyrics
// (see crater/LyricsDSL.h). Plain text is a valid DSL string with no
// markers, so the historical content where every line was bare text
// continues to round-trip unchanged. Formatting (bold, italic, underline,
// color) is encoded inline:
//
//     "Amazing {color=red}grace{/color}, how **sweet** the sound"
//
// Runs (the structured, per-character formatting representation) are an
// in-memory editing detail — they live transiently inside the song editor
// and the renderer, both of which parse the DSL on entry and serialize
// back to DSL on save. The storage shape stays string-flat so this struct
// remains a tidy Q_GADGET value type.
struct SongSection
{
    Q_GADGET
    QML_VALUE_TYPE(songSection)
    Q_PROPERTY(QString     label     MEMBER label)
    Q_PROPERTY(QString     kind      MEMBER kind)     // "verse" | "chorus" | "bridge" | ...
    Q_PROPERTY(QStringList lines     MEMBER lines)    // DSL-formatted strings, one per line
    Q_PROPERTY(int         sortOrder MEMBER sortOrder)

public:
    QString     label;
    QString     kind;
    QStringList lines;
    int         sortOrder = 0;

    // C++20 defaulted equality — required by MOC for Q_PROPERTY change detection
    // when this type appears as the element of a QList in another Q_GADGET.
    bool operator==(const SongSection&) const = default;
};

}  // namespace crater
