#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

#include <memory>

namespace crater {

// In-memory state for the projection output. ProjectionWindow.qml binds to
// these Q_PROPERTYs and re-renders whenever stateChanged() fires.
//
// "Snapshot" semantics: goLive() copies the schedule item into m_currentItem.
// Subsequent edits to the schedule (e.g. user adds a verse to a song) do NOT
// affect the live output until they explicitly re-Go-Live. This is critical
// for stage stability — you don't want a typo in the song editor to show up
// on the audience screen mid-service.
//
// Themes are NOT snapshotted here. ProjectionWindow.qml resolves the
// effective theme reactively from `currentItem.themeId` (per-item override)
// and ThemeService.defaultFor(kind) — so when the operator changes the
// kind's default theme via the Themes tab, the live projection re-renders
// immediately. Matches Electron's RenderProjection.tsx createMemo pattern.
class ProjectionService : public QObject
{
    Q_OBJECT

    // Bundled NOTIFY — all projection bindings re-evaluate together. For a
    // handful of properties on a single subscriber (ProjectionWindow.qml),
    // this is simpler than per-property NOTIFY signals and equally cheap.
    Q_PROPERTY(QString        contentKind  READ contentKind  NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap    currentItem  READ currentItem  NOTIFY stateChanged)
    Q_PROPERTY(int            pageIndex    READ pageIndex    NOTIFY stateChanged)
    Q_PROPERTY(int            pageCount    READ pageCount    NOTIFY stateChanged)
    Q_PROPERTY(bool           isClear      READ isClear      NOTIFY stateChanged)
    Q_PROPERTY(bool           showLogo     READ showLogo     NOTIFY stateChanged)
    // Persistent reference to the projection's "logo / pre-service"
    // background. Two coupled fields — path is the absolute file path
    // inside MediaService's managed dir, kind is "image" | "video" so the
    // renderer can pick `Image` vs `VideoOutput` (or its MediaMonitor
    // equivalent). Both live here (not in AppState) because they're user
    // data the projection actually renders — per ARCHITECTURE.md §1/§9
    // anything disk-backed belongs in crater-core. Backed by the `kv`
    // table; written atomically via setLogoBg().
    Q_PROPERTY(QString        logoBgPath   READ logoBgPath   NOTIFY logoBgPathChanged)
    Q_PROPERTY(QString        logoBgKind   READ logoBgKind   NOTIFY logoBgKindChanged)

public:
    explicit ProjectionService(QObject* parent = nullptr);
    ~ProjectionService() override;

    QString        contentKind()  const { return m_contentKind; }
    QVariantMap    currentItem()  const { return m_currentItem; }
    int            pageIndex()    const { return m_pageIndex; }
    int            pageCount()    const;
    bool           isClear()      const { return m_isClear; }
    bool           showLogo()     const { return m_showLogo; }
    QString        logoBgPath()   const { return m_logoBgPath; }
    QString        logoBgKind()   const { return m_logoBgKind; }

    // Snapshot `item` (deep copy) and set pageIndex. Clears isClear.
    Q_INVOKABLE void goLive(QVariantMap item, int page);

    Q_INVOKABLE void clear();              // shows background only (no content)
    Q_INVOKABLE void setPage(int i);
    Q_INVOKABLE void nextPage();
    Q_INVOKABLE void prevPage();
    Q_INVOKABLE void toggleLogo();
    Q_INVOKABLE void setLogoVisible(bool visible);

    // Set (and persist) the logo background. `kind` is "image" or "video"
    // (matching MediaItem.type — both validated at import time). Pass an
    // empty path to clear; kind is then ignored. Writes both fields and
    // their kv rows atomically, emitting only the signals whose values
    // actually changed.
    Q_INVOKABLE void setLogoBg(QString path, QString kind);

signals:
    void stateChanged();
    void logoBgPathChanged();
    void logoBgKindChanged();

private:
    QVariantMap    m_currentItem;
    QString        m_contentKind;     // "" | "song" | "scripture" | "image" | "video"
    int            m_pageIndex   = 0;
    bool           m_isClear     = false;
    bool           m_showLogo    = false;
    QString        m_logoBgPath;
    QString        m_logoBgKind;     // "" | "image" | "video"

    struct KvImpl;
    std::unique_ptr<KvImpl> m_kv;
};

}  // namespace crater
