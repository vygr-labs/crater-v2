#include "crater/HelpLinks.h"

#include <iterator>

namespace crater {

namespace {

struct Playlist
{
    const char* id;
    const char* url;
};

// Watch order. HelpSection.qml gives each id its label.
constexpr Playlist kPlaylists[] = {
    { "getting-started", "https://www.youtube.com/playlist?list=PLeTrWoINYOdc" },
    { "scripture",       "https://www.youtube.com/playlist?list=PLNO9VmlLIHvc" },
    { "songs",           "https://www.youtube.com/playlist?list=PLcyNZxoeJ3Jg" },
    { "media",           "https://www.youtube.com/playlist?list=PLBAJHRdNjqYQ" },
    { "planning",        "https://www.youtube.com/playlist?list=PLXZDtD0pzOe0" },
    { "themes",          "https://www.youtube.com/playlist?list=PLdevLN2YWRz4" },
    { "screens",         "https://www.youtube.com/playlist?list=PLeIJbC4poGcQ" },
    { "settings",        "https://www.youtube.com/playlist?list=PLegIh7LuDbIU" },
    { "shortcuts",       "https://www.youtube.com/playlist?list=PLaRLc4BRkAx0" },
};

constexpr const char* kChannel = "https://www.youtube.com/@craterbibleproject";
constexpr const char* kDocs    = "https://getcrater.org/docs/";
constexpr const char* kWebsite = "https://getcrater.org/";

}  // namespace

QString HelpLinks::channel() const { return QString::fromLatin1(kChannel); }
QString HelpLinks::docs() const    { return QString::fromLatin1(kDocs); }
QString HelpLinks::website() const { return QString::fromLatin1(kWebsite); }

QStringList HelpLinks::playlistIds() const
{
    QStringList ids;
    ids.reserve(int(std::size(kPlaylists)));
    for (const Playlist& p : kPlaylists) ids.append(QString::fromLatin1(p.id));
    return ids;
}

QString HelpLinks::playlist(const QString& id) const
{
    for (const Playlist& p : kPlaylists)
        if (id == QLatin1String(p.id)) return QString::fromLatin1(p.url);
    return {};
}

}  // namespace crater
