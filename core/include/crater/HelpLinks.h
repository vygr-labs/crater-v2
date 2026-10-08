#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

namespace crater {

// Every web address Crater links to for help: the tutorial channel, its
// playlists, and the docs site. Kept in this one file so a renamed or
// replaced playlist is a one-line change. The labels the operator sees live
// in QML (HelpSection.qml), keyed by the playlist ids below, so they go
// through the normal translation pass.
//
// QML opens these with Qt.openUrlExternally, which hands them to the
// system's default browser.
class HelpLinks : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString channel READ channel CONSTANT)
    Q_PROPERTY(QString docs    READ docs    CONSTANT)
    Q_PROPERTY(QString website READ website CONSTANT)
    Q_PROPERTY(QStringList playlistIds READ playlistIds CONSTANT)

public:
    using QObject::QObject;

    QString channel() const;
    QString docs() const;
    QString website() const;

    // Playlist ids in the order the tutorials are meant to be watched.
    QStringList playlistIds() const;

    // The playlist's address, or an empty string for an unknown id.
    Q_INVOKABLE QString playlist(const QString& id) const;
};

}  // namespace crater
