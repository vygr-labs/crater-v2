#include "PdfPageImageProvider.h"

#include "crater/MediaService.h"

#include <QDebug>
#include <QFutureWatcher>
#include <QQuickTextureFactory>
#include <QUrl>
#include <QUrlQuery>
#include <QtConcurrent>

namespace crater {

namespace {

// One in-flight render. Holds the QFutureWatcher and bridges its `finished`
// signal back into QQuickImageResponse::finished so QML's Image element can
// re-pull the resulting QImage. Self-deletes via deleteLater after the
// image plumbing has picked up the result (Qt's image-cache machinery
// holds the response object until then).
class PdfImageResponse : public QQuickImageResponse
{
public:
    explicit PdfImageResponse(QFuture<QImage> future)
    {
        m_watcher = new QFutureWatcher<QImage>(this);
        connect(m_watcher, &QFutureWatcher<QImage>::finished,
                this, [this]() {
                    m_image = m_watcher->future().resultCount() > 0
                                  ? m_watcher->result()
                                  : QImage{};
                    qInfo().noquote()
                        << "[pdf provider] response finished — image="
                        << m_image.size() << "null=" << m_image.isNull();
                    emit finished();
                });
        m_watcher->setFuture(future);
    }

    QQuickTextureFactory* textureFactory() const override
    {
        return m_image.isNull()
                   ? nullptr
                   : QQuickTextureFactory::textureFactoryForImage(m_image);
    }

private:
    QFutureWatcher<QImage>* m_watcher = nullptr;
    QImage                  m_image;
};

// Parse "12?page=3&cx=0.1&cy=0.2&cw=0.5&ch=0.5" — the leading segment is
// the mediaId; the rest is a standard query string. Defaults fill in for
// any field missing.
struct ParsedRequest {
    qint64  mediaId   = 0;
    int     page      = 0;
    QRectF  cropRect  = QRectF(0, 0, 1, 1);
    bool    valid     = false;
};

ParsedRequest parseRequest(const QString& id)
{
    ParsedRequest out;
    if (id.isEmpty()) return out;

    // Split on the first '?'. QUrlQuery handles the URL-decoding of the
    // tail; we hand-parse the head as a plain integer.
    const int qPos = id.indexOf(QLatin1Char('?'));
    const QString head = (qPos >= 0) ? id.left(qPos)         : id;
    const QString tail = (qPos >= 0) ? id.mid(qPos + 1)      : QString{};

    bool ok = false;
    const qint64 mediaId = head.toLongLong(&ok);
    if (!ok || mediaId <= 0) return out;
    out.mediaId = mediaId;

    QUrlQuery q(tail);
    if (q.hasQueryItem(QStringLiteral("page"))) {
        out.page = q.queryItemValue(QStringLiteral("page")).toInt();
    }
    auto readClipPart = [&](const QString& key, qreal fallback) {
        if (!q.hasQueryItem(key)) return fallback;
        bool partOk = false;
        const qreal v = q.queryItemValue(key).toDouble(&partOk);
        return partOk ? v : fallback;
    };
    const qreal cx = readClipPart(QStringLiteral("cx"), 0.0);
    const qreal cy = readClipPart(QStringLiteral("cy"), 0.0);
    const qreal cw = readClipPart(QStringLiteral("cw"), 1.0);
    const qreal ch = readClipPart(QStringLiteral("ch"), 1.0);
    out.cropRect = QRectF(cx, cy, cw, ch);

    out.valid = true;
    return out;
}

}  // namespace

PdfPageImageProvider::PdfPageImageProvider(MediaService* mediaService)
    : m_mediaService(mediaService)
{
}

QQuickImageResponse* PdfPageImageProvider::requestImageResponse(
    const QString& id, const QSize& requestedSize)
{
    const auto req = parseRequest(id);

    // Pick a sensible target size when QML didn't supply sourceSize. PDFs
    // are vector — we MUST be told what pixel size to rasterize at — so a
    // default 1920×1080 here keeps a missing sourceSize from collapsing to
    // a 1×1 garbage render. Image elements that bind sourceSize correctly
    // (CroppableMediaPreview + ProjectionScene's PDF branch both do) get
    // exactly the resolution they asked for.
    QSize target = requestedSize;
    if (!target.isValid() || target.width() <= 0 || target.height() <= 0) {
        target = QSize(1920, 1080);
    }

    qInfo().noquote()
        << "[pdf provider] request id=\"" << id << "\""
        << "requestedSize=" << requestedSize << "target=" << target
        << "| parsed valid=" << req.valid
        << "mediaId=" << req.mediaId << "page=" << req.page
        << "crop=" << req.cropRect;

    if (!req.valid || !m_mediaService) {
        qWarning().noquote()
            << "[pdf provider] returning null image — valid=" << req.valid
            << "mediaService=" << (m_mediaService != nullptr);
        // Return a response that immediately resolves to a null image so
        // QML's Image cleanly enters the "errored" state rather than
        // hanging on a never-finished watcher. We synthesize via a trivial
        // QtConcurrent::run rather than QtFuture::makeReady* so we don't
        // depend on the exact spelling of Qt's ready-future API across
        // 6.x minor versions.
        return new PdfImageResponse(QtConcurrent::run([]() -> QImage { return {}; }));
    }

    auto future = m_mediaService->renderPdfPage(
        req.mediaId, req.page, target, req.cropRect);
    return new PdfImageResponse(future);
}

}  // namespace crater
