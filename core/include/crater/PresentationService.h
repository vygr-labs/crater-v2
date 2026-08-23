#pragma once

#include "crater/value/Presentation.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantList>

#include <memory>

namespace crater {

// Presentation decks — sermon notes and any other author-it-yourself slide
// content. Backed by the `presentations` table in app.sqlite (V010).
//
// This service sits alongside SongService rather than inside it because the
// two model genuinely different things. A song is imported or transcribed
// once and then projected many times; its text is structured by the lyric
// DSL and indexed for search. A deck is written for one service, projected
// once, and its "structure" is whatever order the operator typed. Folding
// decks into songs would mean either indexing throwaway text into the song
// FTS table or carving out an exception inside every song query.
//
// Slides travel as a QVariantList of QVariantMaps ({title, body, notes})
// rather than a value-type list. QML edits them in place in the editor
// dialog (append, reorder, delete, retype) and a Q_GADGET list would force a
// conversion on every keystroke; the maps also let the shape grow without a
// C++ change. saveSlides() is the boundary that normalizes them, so nothing
// unvalidated reaches the DB no matter what QML sends.
//
// All methods are synchronous (ARCHITECTURE.md §3): a deck is a few KB of
// text, every access is by primary key, and the editor is modal — there is
// nothing to overlap with.
class PresentationService : public QObject
{
    Q_OBJECT

    // Every deck, newest-edited first — the order the library tab shows and
    // the dependency that re-runs its filter when a deck is saved.
    Q_PROPERTY(QList<crater::Presentation> presentations
               READ presentations NOTIFY presentationsChanged)

public:
    explicit PresentationService(QObject* parent = nullptr);
    ~PresentationService() override;

    QList<crater::Presentation> presentations();

    // One deck's header row. Returns a default-constructed Presentation
    // (id == 0) on a miss, matching ThemeService::theme's convention so
    // callers test the id rather than a separate exists() call.
    Q_INVOKABLE crater::Presentation presentation(qint64 id);

    // The deck's slides, in order. Empty list for an unknown id OR for a
    // deck whose stored JSON failed to parse — a corrupted deck reads as
    // empty rather than throwing into a QML binding, and the operator sees
    // an empty editor they can retype into instead of a dead app.
    Q_INVOKABLE QVariantList slides(qint64 id);

    // Create an empty deck. Returns the new id, or 0 on failure / empty
    // title. Seeds one blank slide so the editor opens on something the
    // operator can type into rather than an empty list with a lone
    // "add slide" button.
    Q_INVOKABLE qint64 create(QString title);

    Q_INVOKABLE bool rename(qint64 id, QString title);

    // Replace the deck's slides wholesale. Every map is normalized down to
    // the three known string keys, so a stray property added by a QML model
    // (or a future field this build does not know) cannot reach the stored
    // JSON. Returns true when the write lands.
    Q_INVOKABLE bool saveSlides(qint64 id, QVariantList slides);

    // Per-deck theme override; 0 clears it. Mirrors the per-item themeId
    // that songs and scriptures already carry into resolveItemTheme.
    Q_INVOKABLE void setThemeId(qint64 id, qint64 themeId);

    // Deep-copy including slides. Name becomes "<title> copy". Returns the
    // new id, or 0 on failure.
    Q_INVOKABLE qint64 duplicate(qint64 id);

    Q_INVOKABLE void destroy(qint64 id);

signals:
    void presentationsChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
