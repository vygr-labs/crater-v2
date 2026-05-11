#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

namespace crater {

// In-memory working copy of a theme being edited. Holds the editor's local
// state — never touches the database. Save flows happen externally by
// reading toTokens() and passing it to ThemeService::update / ::create.
//
// Why a QObject and not a `property var` in QML: QML bindings on a deeply
// nested `property var` (e.g. `workingTheme.nodes[2].style.x`) do NOT
// fire when you mutate a sub-path imperatively. Forcing the issue by
// reassigning the whole object every drag tick blows away delegate state
// and tanks frame time. With this QObject and granular NOTIFY signals,
// only the affected node's bindings re-evaluate.
//
// Reactivity contract for editor delegates:
//   - Bind to `workingTheme.nodes` to render the Repeater. Triggered only
//     by structural changes (add/remove/reorder) via nodesChanged().
//   - For per-node property updates, listen to nodeStyleChanged(id, field)
//     and nodeDataChanged(id, field). Re-fetch the node via node(id) and
//     rebind the delegate's `node` property — downstream bindings update.
class WorkingTheme : public QObject
{
    Q_OBJECT

    // canvas: { width, height }. Single object so QML can bind `canvas.width`.
    Q_PROPERTY(QVariantMap  canvas READ canvas NOTIFY canvasChanged)
    // nodes:  ordered list of { id, kind, style: {...}, data: {...} } maps.
    Q_PROPERTY(QVariantList nodes  READ nodes  NOTIFY nodesChanged)

public:
    explicit WorkingTheme(QObject* parent = nullptr);

    QVariantMap  canvas() const { return m_canvas; }
    QVariantList nodes()  const { return m_nodes;  }

    // Replaces the entire working state from a v2 tokens map (the shape
    // stored in themes.tokens_json). Emits nodesChanged + canvasChanged.
    Q_INVOKABLE void loadFrom(QVariantMap tokens);

    // Serializes the current working state back to a v2 tokens map.
    Q_INVOKABLE QVariantMap toTokens() const;

    // Returns a copy of the node with the given id, or an empty map on miss.
    // Delegates re-fetch via this after listening to nodeStyleChanged.
    Q_INVOKABLE QVariantMap node(QString id) const;

    // Returns the index of the node with the given id, or -1 on miss.
    Q_INVOKABLE int indexOf(QString id) const;

    // Mutators. Each emits exactly one granular signal so QML can rebind
    // narrowly without rebuilding the Repeater.
    Q_INVOKABLE void setCanvas(int width, int height);
    Q_INVOKABLE void setNodeStyle(QString id, QString field, QVariant value);
    Q_INVOKABLE void setNodeData (QString id, QString field, QVariant value);
    Q_INVOKABLE void renameNode  (QString id, QString layerName);

    // Structural mutators. These emit nodesChanged().
    // addNode returns the new node's id (so the caller can select it).
    Q_INVOKABLE QString addNode(QString kind);
    Q_INVOKABLE void    removeNode(QString id);
    Q_INVOKABLE QString duplicateNode(QString id);
    // direction: positive = bring forward (+1 z) or to front (>= 100),
    //            negative = send backward (-1) or to back (<= -100).
    Q_INVOKABLE void    reorderZ(QString id, int direction);

signals:
    void canvasChanged();
    void nodesChanged();                                  // structural
    void nodeStyleChanged(QString id, QString field);
    void nodeDataChanged (QString id, QString field);

private:
    QVariantMap  m_canvas;
    QVariantList m_nodes;

    QString makeUniqueId(const QString& kindPrefix) const;
};

}  // namespace crater
