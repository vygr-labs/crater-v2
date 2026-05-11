#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QtQmlIntegration>

namespace crater {

// One section of a song — Verse 1, Chorus, Bridge, etc.
struct SongSection
{
    Q_GADGET
    QML_VALUE_TYPE(songSection)
    Q_PROPERTY(QString     label     MEMBER label)
    Q_PROPERTY(QString     kind      MEMBER kind)     // "verse" | "chorus" | "bridge" | ...
    Q_PROPERTY(QStringList lines     MEMBER lines)
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
