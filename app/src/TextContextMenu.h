#pragma once

#include <QObject>
#include <QPointer>
#include <QPointF>

class QQuickItem;
class QQuickWindow;

namespace crater {

// Right-click menu for every text box in the console window.
//
// Qt Quick's TextInput and TextEdit copy and paste from the keyboard but have
// no right-click menu, so an operator who copies with the mouse gets nothing.
// Rather than wrap each of the console's text boxes, this watches the window:
// a right-click that lands on a text box is taken before the box sees it and
// handed to QML (TextBoxMenu.qml) with the box and where to open, together
// with the box's selection at that moment, so the menu acts on what was
// selected even if the press would have moved it.
//
// It only fires on an editable box or a read-only one the operator can
// select from. Plain Text, and anything drawn over a text box, keep their
// own right-click.
class TextContextMenu : public QObject
{
    Q_OBJECT

public:
    explicit TextContextMenu(QObject* parent = nullptr);

    // Starts watching `window` (the console).
    void attach(QQuickWindow* window);

signals:
    // `target` is the TextInput or TextEdit. x / y are window coordinates.
    void requested(QQuickItem* target, qreal x, qreal y,
                   int selectionStart, int selectionEnd);

protected:
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    QPointer<QQuickWindow> m_window;
    bool m_swallowRelease = false;
};

}  // namespace crater
