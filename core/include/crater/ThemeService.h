#pragma once

#include "crater/value/Theme.h"

#include <QList>
#include <QObject>
#include <QString>
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

signals:
    void allThemesChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    void invalidateCache();
};

}  // namespace crater
