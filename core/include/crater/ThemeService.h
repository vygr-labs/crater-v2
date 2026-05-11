#pragma once

#include "crater/value/Theme.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <memory>

namespace crater {

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

    // Pure validation entry point — used by importFromJson and also exposed
    // to the editor so users see field-level errors before attempting Save.
    // Returns an empty list when tokens are well-formed.
    Q_INVOKABLE QStringList validateTokens(QVariantMap tokens);

    // Serializes a theme as the .craterheme on-disk format (metadata wrapper
    // + tokens body). Returns empty string on miss.
    Q_INVOKABLE QString serializeForExport(qint64 id);

    // Writes a theme's serialized form to disk atomically (QSaveFile).
    // Returns true on success. Does not prompt the user — the caller is
    // expected to have chosen a path (typically via FileDialogService).
    Q_INVOKABLE bool exportTheme(qint64 id, QString filePath);

    // Parses a .craterheme JSON document, validates, and inserts as a new
    // non-builtin theme. Returns the new id, or 0 on failure (call
    // lastImportError() for a human-readable reason). Name collisions
    // append " (Import)", " (Import 2)", etc., within the same themeKind.
    Q_INVOKABLE qint64  importFromJson(QString jsonText);
    Q_INVOKABLE qint64  importThemeFile(QString filePath);
    Q_INVOKABLE QString lastImportError() const;

    // Deep-copies an existing theme (built-in or user) with a new name.
    // Returns the new id, or 0 on failure.
    Q_INVOKABLE qint64 duplicateTheme(qint64 id, QString newName);

signals:
    void allThemesChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    QString m_lastImportError;
    void invalidateCache();
};

}  // namespace crater
