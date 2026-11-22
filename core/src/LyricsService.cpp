// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

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

QString LyricsService::htmlToDsl(const QString& html) const
{
    return lyrics::htmlToDsl(html);
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
