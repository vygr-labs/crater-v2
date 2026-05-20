#pragma once

#include <QImage>
#include <QQuickAsyncImageProvider>
#include <QQuickImageResponse>
#include <QRectF>
#include <QSize>
#include <QString>

namespace crater { class MediaService; }

namespace crater {

// QML image provider for PDF pages.
//
// URL scheme: image://pdfpage/<mediaId>?page=N&cx=X&cy=Y&cw=W&ch=H
//   • <mediaId>   — required, integer; resolves to a row in MediaService
//   • page=N      — page index (0-based); defaults to 0
//   • cx,cy,cw,ch — normalized crop rect in 0..1 (origin top-left).
//                   All four optional; missing → full page {0,0,1,1}.
//
// We extend QQuickAsyncImageProvider (not the sync QQuickImageProvider)
// because page rasterization is >5 ms and per ARCHITECTURE.md §3 anything
// slower than that must not block the calling thread. Async also lets QML's
// own image cache do its work — repeated requests for the same URL re-hit
// the cache and skip even the worker dispatch.
//
// The provider holds a non-owning pointer to MediaService; lifetimes are
// guaranteed by main.cpp (both live for the duration of the app).
class PdfPageImageProvider : public QQuickAsyncImageProvider
{
public:
    explicit PdfPageImageProvider(MediaService* mediaService);

    QQuickImageResponse* requestImageResponse(const QString& id,
                                              const QSize&   requestedSize) override;

private:
    MediaService* m_mediaService = nullptr;
};

}  // namespace crater
