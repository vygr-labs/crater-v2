#include "ClipboardService.h"

#include <QClipboard>
#include <QGuiApplication>

namespace crater {

ClipboardService::ClipboardService(QObject* parent)
    : QObject(parent)
{
}

void ClipboardService::setText(const QString& text)
{
    if (text.isEmpty()) {
        return;
    }
    if (QClipboard* clipboard = QGuiApplication::clipboard()) {
        clipboard->setText(text);
    }
}

}  // namespace crater
