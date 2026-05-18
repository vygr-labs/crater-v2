#include "crater/LyricsService.h"

#include "crater/LyricsDSL.h"

namespace crater {

LyricsService::LyricsService(QObject* parent)
    : QObject(parent)
{}

QString LyricsService::dslToHtml(const QString& dsl, const QString& textTransform) const
{
    return lyrics::dslToHtml(dsl, textTransform);
}

QString LyricsService::flattenLine(const QString& dslLine) const
{
    return lyrics::flattenLine(dslLine);
}

QStringList LyricsService::namedColors() const
{
    return lyrics::namedColors();
}

QString LyricsService::resolveColor(const QString& nameOrHex) const
{
    return lyrics::resolveColor(nameOrHex);
}

}  // namespace crater
