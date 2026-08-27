#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
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
// ── One theme, several layouts ─────────────────────────────────────────
// Since tokens v3 a theme carries a LIST of named layouts (title slide,
// section divider, two columns, …) rather than one flat node list — see
// crater/ThemeTokens.h for the format and the reasoning.
//
// The editor still edits ONE design at a time, so this class models that
// directly: `layouts` is the whole set, `currentLayoutId` picks the one
// being worked on, and `nodes` READS THROUGH to that layout's node list.
// Every existing node mutator therefore keeps operating on "the nodes",
// and the canvas, layers panel and properties panel needed no change to
// follow a layout switch — they already rebind on nodesChanged(), which a
// switch emits.
//
// Read-through rather than a checked-out copy is deliberate. Caching the
// current layout's nodes in a second member would mean every new method
// has to remember to flush it back before touching `layouts`, and the
// failure mode of forgetting is silent data loss on save.
//
// Reactivity contract for editor delegates:
//   - Bind to `workingTheme.nodes` to render the Repeater. Triggered by
//     structural changes (add/remove/reorder) AND by a layout switch.
//   - Bind to `workingTheme.layouts` for the layout rail; it fires on
//     add/remove/rename/reorder/default, never on a node edit.
//   - For per-node property updates, listen to nodeStyleChanged(id, field)
//     and nodeDataChanged(id, field). Re-fetch the node via node(id) and
//     rebind the delegate's `node` property — downstream bindings update.
class WorkingTheme : public QObject
{
    Q_OBJECT

    // canvas: { width, height }. Single object so QML can bind `canvas.width`.
    // Shared by every layout: one theme paints to one output.
    Q_PROPERTY(QVariantMap  canvas          READ canvas          NOTIFY canvasChanged)
    // nodes: the CURRENT layout's ordered list of
    //        { id, kind, style: {...}, data: {...} } maps.
    Q_PROPERTY(QVariantList nodes           READ nodes           NOTIFY nodesChanged)
    // layouts: every layout, in author order. Each is
    //          { id, name, default: bool, nodes: [...] }.
    Q_PROPERTY(QVariantList layouts         READ layouts         NOTIFY layoutsChanged)
    // currentLayoutId: which one `nodes` reads through to. Empty only when
    // the theme somehow has no layouts at all.
    Q_PROPERTY(QString      currentLayoutId READ currentLayoutId NOTIFY currentLayoutChanged)

public:
    explicit WorkingTheme(QObject* parent = nullptr);

    QVariantMap  canvas()  const { return m_canvas; }
    QVariantList layouts() const { return m_layouts; }
    QVariantList nodes()   const;
    QString      currentLayoutId() const;

    // Replaces the entire working state from a tokens map. Accepts v2 as
    // well as v3 — a v2 map reads as one implicit default layout, so an
    // un-migrated theme opens in the editor and saves back as v3.
    //
    // The current layout SELECTION survives when the incoming tokens still
    // contain that id. That is what keeps undo/redo usable: history
    // snapshots are whole-theme, so without this an undo of a nudge on the
    // Quote design would bounce the editor back to the default design. The
    // FIRST load is exempt and always lands on the default — see m_loaded.
    Q_INVOKABLE void loadFrom(QVariantMap tokens);

    // Serializes the current working state back to a v3 tokens map.
    Q_INVOKABLE QVariantMap toTokens() const;

    // Returns a copy of the node with the given id from the CURRENT layout,
    // or an empty map on miss. Delegates re-fetch via this after listening
    // to nodeStyleChanged.
    Q_INVOKABLE QVariantMap node(QString id) const;

    // Returns the index of the node within the current layout, or -1.
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
    // Reassigns z densely from a top-to-bottom (front-most first) ordered id
    // list — the Layers panel's drag-reorder commit. Front gets the highest
    // z so the canvas/projection z-sort reproduces the list order exactly.
    // Emits nodesChanged() once.
    Q_INVOKABLE void    reorderNodes(QStringList orderedIdsFrontToBack);

    // ── Layouts ────────────────────────────────────────────────────────

    // Copy of one layout (without switching to it), or an empty map.
    Q_INVOKABLE QVariantMap layout(QString layoutId) const;
    // Index within `layouts`, or -1.
    Q_INVOKABLE int         indexOfLayout(QString layoutId) const;
    // True when a layout with this exact id exists.
    Q_INVOKABLE bool        hasLayout(QString layoutId) const;
    // The standard ids (ThemeTokens.h) this theme has NOT used yet — what
    // an "add design" menu should offer, so authors reach for the shared
    // vocabulary before minting an id no other theme can honour.
    Q_INVOKABLE QStringList unusedStandardLayoutIds() const;

    // Switches which layout `nodes` reads through to. No-op on an unknown
    // id. Emits currentLayoutChanged() + nodesChanged().
    Q_INVOKABLE void setCurrentLayout(QString layoutId);

    // Adds a layout and returns its id (empty on failure).
    //
    // `layoutId` empty mints a unique custom id; otherwise it must be
    // unused. `name` empty falls back to the standard name for the id.
    //
    // The new layout is NOT blank: it inherits the default layout's chrome
    // (backgrounds, decorative containers, custom text) and gets fresh
    // content nodes for the slots that id implies, styled from an existing
    // text node so it matches the theme rather than the hardcoded editor
    // defaults. A design that starts off-brand is a design the author has
    // to rebuild by hand, which defeats the point of a template.
    Q_INVOKABLE QString addLayout(QString layoutId, QString name);

    // Deep-copies a layout, inserting the copy directly after it. Node ids
    // are re-minted: they only have to be unique within a layout, but a
    // copy that shared them would make the two designs' group member lists
    // indistinguishable the moment either is edited.
    Q_INVOKABLE QString duplicateLayout(QString layoutId);

    // Removes a layout. Refuses to remove the last one — a theme with no
    // design renders nothing at all. Removing the default promotes the
    // first survivor, so the "exactly one default" invariant holds.
    Q_INVOKABLE void removeLayout(QString layoutId);

    Q_INVOKABLE void renameLayout(QString layoutId, QString name);

    // Makes this the layout every non-presentation kind renders, and the
    // fallback for a slide whose id this theme does not define. Clears the
    // flag everywhere else.
    Q_INVOKABLE void setDefaultLayout(QString layoutId);

    // Moves a layout by `delta` positions within the list (-1 = left).
    // Clamped; a no-op move emits nothing.
    Q_INVOKABLE void moveLayout(QString layoutId, int delta);

signals:
    void canvasChanged();
    void nodesChanged();                       // structural, or a layout switch
    void nodeStyleChanged(QString id, QString field);
    void nodeDataChanged (QString id, QString field);
    void layoutsChanged();                     // add/remove/rename/reorder/default
    void currentLayoutChanged();

private:
    QVariantMap  m_canvas;
    QVariantList m_layouts;
    int          m_current = 0;      // index into m_layouts
    // False until the first loadFrom(). Distinguishes the constructor's
    // placeholder layout from a real one, so opening a theme lands on the
    // design it flags default rather than on whichever one shares the
    // placeholder's id.
    bool         m_loaded  = false;

    // Writes a node list back into the current layout. Every node mutator
    // funnels through here, which is why `nodes` can stay read-through.
    void putNodes(const QVariantList& nodes);

    QString makeUniqueId(const QString& kindPrefix) const;
    QString makeUniqueLayoutId() const;
    // Ensures exactly one layout carries "default": true, promoting the
    // first when none does. Called after every structural layout change.
    void    normalizeDefault();
};

}  // namespace crater
