#include "TextContextMenu.h"

#include <QMouseEvent>
#include <QQuickItem>
#include <QQuickWindow>

#include <algorithm>

namespace crater {

namespace {

bool isTextBox(const QQuickItem* item)
{
    if (!item->inherits("QQuickTextInput") && !item->inherits("QQuickTextEdit")) return false;
    // A read-only box only counts when its text can be selected. Read-only
    // without that is a label drawn with a text editor.
    return !item->property("readOnly").toBool() || item->property("selectByMouse").toBool();
}

// The topmost item at `scenePos` that takes mouse input or is a text box,
// searched the way Qt delivers a click: last-painted child first.
QQuickItem* topmostAt(QQuickItem* item, const QPointF& scenePos)
{
    if (!item->isVisible() || !item->isEnabled() || item->opacity() <= 0.0) return nullptr;
    const QPointF local = item->mapFromScene(scenePos);
    if (item->clip() && !item->contains(local)) return nullptr;

    QList<QQuickItem*> kids = item->childItems();
    std::stable_sort(kids.begin(), kids.end(),
                     [](const QQuickItem* a, const QQuickItem* b) { return a->z() < b->z(); });
    for (auto it = kids.crbegin(); it != kids.crend(); ++it)
        if (QQuickItem* hit = topmostAt(*it, scenePos)) return hit;

    if (item->contains(local)
        && (item->acceptedMouseButtons() != Qt::NoButton || isTextBox(item)))
        return item;
    return nullptr;
}

}  // namespace

TextContextMenu::TextContextMenu(QObject* parent)
    : QObject(parent)
{}

void TextContextMenu::attach(QQuickWindow* window)
{
    if (m_window) m_window->removeEventFilter(this);
    m_window = window;
    if (m_window) m_window->installEventFilter(this);
}

bool TextContextMenu::eventFilter(QObject* watched, QEvent* event)
{
    if (watched != m_window) return false;

    if (event->type() == QEvent::MouseButtonRelease && m_swallowRelease) {
        if (static_cast<QMouseEvent*>(event)->button() == Qt::RightButton) {
            m_swallowRelease = false;
            return true;
        }
        return false;
    }
    if (event->type() != QEvent::MouseButtonPress) return false;
    auto* mouse = static_cast<QMouseEvent*>(event);
    if (mouse->button() != Qt::RightButton) return false;

    const QPointF pos = mouse->scenePosition();
    // Whatever is on top there decides. A row, a button or a canvas node
    // over the text keeps its own right-click.
    QQuickItem* hit = topmostAt(m_window->contentItem(), pos);
    if (!hit || !isTextBox(hit)) return false;

    m_swallowRelease = true;
    emit requested(hit, pos.x(), pos.y(),
                   hit->property("selectionStart").toInt(),
                   hit->property("selectionEnd").toInt());
    return true;
}

}  // namespace crater
