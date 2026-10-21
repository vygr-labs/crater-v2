#include "ClipboardService.h"

#include <QClipboard>
#include <QDebug>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QQuickItem>
#include <QTimer>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#endif

#include <cstring>

namespace crater {

namespace {

bool isTextBox(const QObject* o)
{
    return o && (o->inherits("QQuickTextInput") || o->inherits("QQuickTextEdit"));
}

// What the box would put on the clipboard as plain text. A TextEdit reports
// paragraph and line breaks as U+2029 / U+2028.
QString selectionOf(const QObject* box)
{
    QString text = box->property("selectedText").toString();
    text.replace(QChar::ParagraphSeparator, QLatin1Char('\n'));
    text.replace(QChar::LineSeparator, QLatin1Char('\n'));
    return text;
}

// A password field never copies, and a read-only box never cuts, so there
// is nothing to fall back to.
bool copiesSelection(const QObject* box, bool cut)
{
    if (cut && box->property("readOnly").toBool()) return false;
    const QVariant echo = box->property("echoMode");
    return !echo.isValid() || echo.toInt() == 0;
}

#ifdef Q_OS_WIN

quint32 clipboardSequence()
{
    return GetClipboardSequenceNumber();
}

// The clipboard needs an owner window: opened with none, EmptyClipboard sets
// the owner to null and SetClipboardData then fails. A hidden message-only
// window of our own, so this never depends on how Qt made its windows (an
// offscreen window's id is not a real HWND).
HWND ownerWindow()
{
    static HWND owner = CreateWindowExW(0, L"STATIC", L"Crater clipboard", 0, 0, 0, 0, 0,
                                        HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
    return owner;
}

// Plain-text write through the Win32 clipboard. Retries a few times because
// another program can hold the clipboard open for a moment.
bool writeWin32Text(const QString& text, DWORD* error)
{
    QString crlf = text;
    crlf.replace(QLatin1String("\r\n"), QLatin1String("\n"));
    crlf.replace(QLatin1Char('\n'), QLatin1String("\r\n"));

    const HWND owner = ownerWindow();
    *error = 0;
    for (int attempt = 0; attempt < 5; ++attempt) {
        if (attempt > 0) Sleep(40);
        if (!OpenClipboard(owner)) { *error = GetLastError(); continue; }
        bool ok = false;
        if (EmptyClipboard()) {
            const SIZE_T bytes = (SIZE_T(crlf.size()) + 1) * sizeof(wchar_t);
            if (HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
                if (void* p = GlobalLock(mem)) {
                    std::memcpy(p, crlf.utf16(), bytes - sizeof(wchar_t));
                    static_cast<wchar_t*>(p)[crlf.size()] = L'\0';
                    GlobalUnlock(mem);
                    ok = SetClipboardData(CF_UNICODETEXT, mem) != nullptr;
                }
                if (!ok) { *error = GetLastError(); GlobalFree(mem); }
            }
        } else {
            *error = GetLastError();
        }
        CloseClipboard();
        if (ok) return true;
    }
    return false;
}

// Called after Qt has had its go. If the clipboard never changed, Qt's write
// failed, so write the text ourselves.
void ensureCopied(quint32 before, const QString& text)
{
    if (text.isEmpty()) return;
    if (clipboardSequence() != before && IsClipboardFormatAvailable(CF_UNICODETEXT)) return;

    DWORD error = 0;
    if (writeWin32Text(text, &error))
        qInfo() << "Clipboard: Qt's copy did not reach the clipboard, wrote"
                << text.size() << "characters through Win32 instead";
    else
        qWarning() << "Clipboard: copy failed through both Qt and Win32, error" << error;
}

#else

quint32 clipboardSequence() { return 0; }
void ensureCopied(quint32, const QString&) {}

#endif

}  // namespace

ClipboardService::ClipboardService(QObject* parent)
    : QObject(parent)
{
    if (QCoreApplication* app = QCoreApplication::instance())
        app->installEventFilter(this);
}

void ClipboardService::setText(const QString& text)
{
    if (text.isEmpty()) {
        return;
    }
    if (QClipboard* clipboard = QGuiApplication::clipboard()) {
        const quint32 before = clipboardSequence();
        clipboard->setText(text);
        ensureCopied(before, text);
    }
}

void ClipboardService::copySelection(QQuickItem* textBox)
{
    copyOrCut(textBox, "copy");
}

void ClipboardService::cutSelection(QQuickItem* textBox)
{
    copyOrCut(textBox, "cut");
}

void ClipboardService::copyOrCut(QQuickItem* textBox, const char* method)
{
    if (!isTextBox(textBox)) return;
    const bool cut = std::strcmp(method, "cut") == 0;
    const QString text = copiesSelection(textBox, cut) ? selectionOf(textBox) : QString();
    const quint32 before = clipboardSequence();
    QMetaObject::invokeMethod(textBox, method);
    ensureCopied(before, text);
}

bool ClipboardService::eventFilter(QObject* watched, QEvent* event)
{
    // The window sees each key once. The items it then hands the key to
    // would show it here again.
    if (event->type() != QEvent::KeyPress || !watched->isWindowType()) return false;
    auto* key = static_cast<QKeyEvent*>(event);
    const bool cut = key->matches(QKeySequence::Cut);
    if (!cut && !key->matches(QKeySequence::Copy)) return false;

    QObject* box = QGuiApplication::focusObject();
    // A box that gives Ctrl+C another job (the console search clears the
    // screen with it) says so, and its key is left alone.
    if (!isTextBox(box) || !copiesSelection(box, cut) || box->property("ownsCopyKey").toBool())
        return false;
    const QString text = selectionOf(box);
    if (text.isEmpty()) return false;

    // The box copies while it handles this key, after the filter returns.
    QTimer::singleShot(0, this, [before = clipboardSequence(), text] {
        ensureCopied(before, text);
    });
    return false;
}

}  // namespace crater
