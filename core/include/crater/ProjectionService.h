#pragma once

#include "crater/value/Theme.h"

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
    Q_PROPERTY(crater::Theme  currentTheme READ currentTheme NOTIFY stateChanged)
    Q_PROPERTY(bool           isClear      READ isClear      NOTIFY stateChanged)
    Q_PROPERTY(bool           showLogo     READ showLogo     NOTIFY stateChanged)
    // Persistent path to the projection's "logo / pre-service" background
    // image. Lives here (not in AppState) because it's user data the
    // projection actually renders — per ARCHITECTURE.md §1/§9 anything
    // disk-backed belongs in crater-core. Backed by the `kv` table.
    Q_PROPERTY(QString        logoBgPath   READ logoBgPath   NOTIFY logoBgPathChanged)

public:
    explicit ProjectionService(QObject* parent = nullptr);
    ~ProjectionService() override;

    QString        contentKind()  const { return m_contentKind; }
    QVariantMap    currentItem()  const { return m_currentItem; }
    int            pageIndex()    const { return m_pageIndex; }
    int            pageCount()    const;
    crater::Theme  currentTheme() const { return m_currentTheme; }
    bool           isClear()      const { return m_isClear; }
    bool           showLogo()     const { return m_showLogo; }
    QString        logoBgPath()   const { return m_logoBgPath; }

    // Snapshot `item` (deep copy) and theme; set pageIndex. Clears isClear.
    Q_INVOKABLE void goLive(QVariantMap item, int page, crater::Theme theme);

    Q_INVOKABLE void clear();              // shows background only (no content)
    Q_INVOKABLE void setPage(int i);
    Q_INVOKABLE void nextPage();
    Q_INVOKABLE void prevPage();
    Q_INVOKABLE void toggleLogo();
    Q_INVOKABLE void setLogoVisible(bool visible);

    // Set (and persist) the path to the background image shown when nothing
    // is live or the logo overlay is enabled. Pass empty string to clear.
    Q_INVOKABLE void setLogoBgPath(QString path);

signals:
    void stateChanged();
    void logoBgPathChanged();

private:
    QVariantMap    m_currentItem;
    QString        m_contentKind;     // "" | "song" | "scripture" | "image" | "video"
    int            m_pageIndex   = 0;
    crater::Theme  m_currentTheme;
    bool           m_isClear     = false;
    bool           m_showLogo    = false;
    QString        m_logoBgPath;

    struct KvImpl;
    std::unique_ptr<KvImpl> m_kv;
};

}  // namespace crater
