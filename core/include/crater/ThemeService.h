#pragma once

#include "crater/value/Theme.h"
#include "crater/value/ThemeImportReport.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <memory>

namespace crater {

class MediaService;
class FontService;

// Theme service — CRUD over themes table in app.sqlite.
//
// Themes are declarative token data (JSON in DB). The kv table stores
// per-kind default theme ids (e.g. `default_song_theme_id` -> 1) so the
// projection can resolve "default theme for song" without a separate API.
class ThemeService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QList<crater::Theme> allThemes READ allThemes NOTIFY allThemesChanged)

public:
    explicit ThemeService(QObject* parent = nullptr);
    ~ThemeService() override;

    // Wire MediaService + FontService so export/import can bundle and
    // restore referenced assets (ARCHITECTURE.md §10). Call once at
    // startup, before any export/import. Optional — ThemeService still
    // works without these wired for non-asset operations (CRUD, default
    // selection, validation), making it testable in isolation.
    void setMediaService(MediaService* media);
    void setFontService(FontService* font);

    QList<crater::Theme> allThemes();

    // Full theme by id; returns empty Theme on miss.
    Q_INVOKABLE crater::Theme theme(qint64 id);

    // Returns the user-selected default theme for a content kind ("song",
    // "scripture", "presentation"). Falls back to the first built-in of that
    // kind if no explicit default is set.
    Q_INVOKABLE crater::Theme defaultFor(QString kind);

    // Persists the user's default theme selection for a kind. Updates the
    // `kv` table; idempotent.
    Q_INVOKABLE void setDefaultFor(QString kind, qint64 themeId);

    // CRUD.
    Q_INVOKABLE qint64 create(QString kind, QString name, QVariantMap tokens);
    Q_INVOKABLE void   update(qint64 id, QString name, QVariantMap tokens);
    Q_INVOKABLE void   destroy(qint64 id);

    // Pure validation entry point — used by importThemeFile and also
    // exposed to the editor so users see field-level errors before
    // attempting Save. Returns an empty list when tokens are well-formed.
    Q_INVOKABLE QStringList validateTokens(QVariantMap tokens);

    // ── Export (ARCHITECTURE.md §10) ────────────────────────────────────
    // Returns the proposed contents of a .craterheme v2 bundle for theme
    // `id`. Used by the export confirmation dialog (Stage 6b) to show the
    // user which media and fonts will be embedded BEFORE the file is
    // written, so they can opt fonts out before redistribution. Shape:
    //   {
    //     "themeName": "...", "themeKind": "...", "appVersion": "...",
    //     "media": [{ "mediaId": 47, "title": "...", "sourcePath": "...",
    //                 "sizeBytes": 12345, "type": "image"|"video"|"pdf" }, ...],
    //     "fonts": {
    //       "bundleable": [{ "family": "Inter", "sourcePath": "...",
    //                        "sizeBytes": 218904 }, ...],
    //       "systemOnly": ["Arial", ...]
    //     }
    //   }
    // Returns an empty map when the theme id doesn't resolve.
    Q_INVOKABLE QVariantMap resolveExportPlan(qint64 id);

    // Writes a .craterheme v2 bundle (zip) to `filePath` atomically.
    // Bundles every referenced media file plus every bundleable font
    // EXCEPT those whose family appears in `excludedFontFamilies`. The
    // export dialog passes its opt-out list here; programmatic callers
    // pass an empty list to bundle everything resolvable.
    //
    // Returns true on success; on failure see lastExportError().
    Q_INVOKABLE bool exportTheme(qint64       id,
                                 QString      filePath,
                                 QStringList  excludedFontFamilies = {});

    Q_INVOKABLE QString lastExportError() const;

    // ── Import (ARCHITECTURE.md §10) ────────────────────────────────────
    // Reads a .craterheme v2 bundle and inserts it as a new non-builtin
    // theme. Best-effort: per-asset failures populate the import report
    // but do not abort. Catastrophic failures (not a zip, manifest
    // invalid, theme INSERT fails) roll back and leave themeId == 0.
    //
    // Name collisions append " (Import)", " (Import 2)", etc., within
    // the same themeKind.
    //
    // v1 (JSON-only) files are deliberately not supported — they would
    // import with broken mediaId references; we refuse with a clear error
    // pointing the user at re-exporting from the original install.
    Q_INVOKABLE crater::ThemeImportReport importThemeFile(QString filePath);

    // Imports a plain-JSON theme — the format a designer (or Claude) authors
    // by hand. The file is a single JSON object:
    //   { "name": "...", "kind": "song"|"scripture"|"presentation",
    //     "tokens": { "version": 2, "canvas": {...}, "nodes": [...] } }
    // Validates the tokens and inserts a new non-builtin theme with a
    // collision-safe name. Returns the new id, or 0 on failure — see
    // lastImportError() for the parse / validation message.
    //
    // Distinct from importThemeFile (the .craterheme ZIP bundle): a JSON theme
    // references no bundled media/font assets, so it skips the entire asset
    // relocation machinery — gradients, solid colors and system fonts only.
    // See qt/docs/theme-schema.md for the authored format.
    Q_INVOKABLE qint64 importThemeJsonFile(QString filePath);

    Q_INVOKABLE QString lastImportError() const;

    // Removes any leftover .import-staging/<uuid>/ directories from a
    // process kill mid-import. Idempotent. Call once at startup, after
    // FontService and MediaService are constructed (Stage 7c).
    static void sweepImportStaging();

    // Deep-copies an existing theme (built-in or user) with a new name.
    // Returns the new id, or 0 on failure.
    Q_INVOKABLE qint64 duplicateTheme(qint64 id, QString newName);

signals:
    void allThemesChanged();
    // Fires when a default-for-kind selection changes. Separate from
    // allThemesChanged because the kv-table writes done by setDefaultFor
    // don't touch the themes table — overloading allThemesChanged would
    // force every tile to recompute on unrelated edits.
    void defaultsChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    QString m_lastImportError;
    QString m_lastExportError;
    MediaService* m_media = nullptr;
    FontService*  m_fonts = nullptr;
    void invalidateCache();
};

}  // namespace crater
