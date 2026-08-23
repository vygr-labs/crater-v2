#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A presentation deck — the sermon-notes / slide content type.
//
// Crater already had three ways to put words on a screen (a song's lyric
// sections, a scripture passage, a Strong's definition) and all three are
// *lookups*: the operator finds existing text and projects it. A deck is the
// missing fourth case, where the words do not exist anywhere until somebody
// writes them — sermon points, announcements, a welcome slide, an offering
// verse the preacher typed on Saturday night.
//
// The row itself is deliberately thin. `slideCount` is derived at query
// time from the stored JSON so the library tile can show "6 slides" without
// parsing every deck, and the slides themselves live in one JSON column
// rather than a child table: a deck is read and written whole (the editor
// loads all of it, saves all of it), it is small, and nothing ever queries
// across slides. A join table would buy ordering and partial reads that
// nothing asks for. Contrast songs, where the lyric DSL genuinely needs
// section-level structure and FTS indexing.
//
// Each slide is { title, body, notes }:
//   title — the heading, bound by a presentation theme's `presentationTitle`
//           text node.
//   body  — the content, bound by `presentationBody`.
//   notes — the preacher's SPEAKER notes. Deliberately never rendered to the
//           audience: they reach the confidence monitor only, through a
//           stage-mode output (see OutputBinding::contentMode). This is the
//           half of "display scripture and sermon notes on separate screens"
//           that the audience must never see.
//
// Any of the three may be empty. That is the whole layout system: a theme
// stacks its title and body nodes in a group card that hugs its content, so
// a title with no body renders as a section divider and a body with no title
// renders as a plain content slide, with no per-slide layout enum to keep in
// sync with the theme.
struct Presentation
{
    Q_GADGET
    QML_VALUE_TYPE(presentation)
    Q_PROPERTY(qint64  id         MEMBER id)
    Q_PROPERTY(QString title      MEMBER title)
    Q_PROPERTY(int     slideCount MEMBER slideCount)
    // Per-deck theme override, mirroring Song.themeId. 0 means "no override
    // — resolve through the per-output presentation slot, then the per-kind
    // default", which is what AppState.resolveItemTheme already does for
    // every other kind.
    Q_PROPERTY(qint64  themeId    MEMBER themeId)
    Q_PROPERTY(qint64  updatedAt  MEMBER updatedAt)

public:
    qint64  id         = 0;
    QString title;
    int     slideCount = 0;
    qint64  themeId    = 0;
    qint64  updatedAt  = 0;
};

}  // namespace crater
