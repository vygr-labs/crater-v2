#include "BrowserCastService.h"

#include "crater/ProjectionService.h"

#include <QBuffer>
#include <QByteArray>
#include <QDebug>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QHostAddress>
#include <QImage>
#include <QList>
#include <QNetworkInterface>
#include <QPointer>
#include <QQuickItem>
#include <QQuickItemGrabResult>
#include <QSet>
#include <QSharedPointer>
#include <QSize>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>

#include <utility>

namespace crater {

namespace {

// Capture cadence and frame sizing. The projection canvas is 1920x1080;
// frames are downscaled (aspect-preserving) so a weak TV browser's JPEG
// decoder keeps up and LAN bandwidth stays modest. ~12 fps is plenty for
// slides and tolerable for motion backgrounds — full-screen video clips
// take the native-<video> path instead, so this rate never gates them.
constexpr int     kGrabIntervalMs  = 80;            // ~12 fps
constexpr int     kMaxFrameWidth   = 1280;
constexpr int     kMaxFrameHeight  = 720;
constexpr int     kJpegQuality     = 78;
constexpr qint64  kKeepAliveMs     = 1000;          // resend an unchanged frame at most this often
constexpr qint64  kVideoChunkBytes = 256 * 1024;    // /video pump chunk
constexpr qint64  kSlowClientLimit = 2 * 1024 * 1024;  // drop MJPEG frames for a backed-up client
constexpr int     kGrabWatchdogMs  = 2000;          // recover if a grab never reports ready

// Ports tried in order. 7373 first ("cRATER" on a phone keypad-ish); the
// rest are fallbacks in case something else already holds the port.
const quint16 kPortCandidates[] = { 7373, 7374, 7375, 8099 };

QByteArray mimeForVideo(const QString& path)
{
    const QString ext = QFileInfo(path).suffix().toLower();
    if (ext == QLatin1String("webm")) return "video/webm";
    if (ext == QLatin1String("ogv") || ext == QLatin1String("ogg")) return "video/ogg";
    if (ext == QLatin1String("mov")) return "video/quicktime";
    if (ext == QLatin1String("mkv")) return "video/x-matroska";
    if (ext == QLatin1String("avi")) return "video/x-msvideo";
    // mp4 / m4v / unknown — mp4 is the safe default for TV browsers.
    return "video/mp4";
}

// Pick a LAN-facing IPv4 address for the URL we show the operator. Private
// ranges (192.168/10/172) are preferred; any non-loopback IPv4 is the
// fallback; localhost is the last resort (server still bound, just not
// reachable from another device).
QString detectLanUrl(quint16 port)
{
    QString fallback;
    const auto interfaces = QNetworkInterface::allInterfaces();
    for (const QNetworkInterface& iface : interfaces) {
        const auto flags = iface.flags();
        if (!flags.testFlag(QNetworkInterface::IsUp)) continue;
        if (!flags.testFlag(QNetworkInterface::IsRunning)) continue;
        if (flags.testFlag(QNetworkInterface::IsLoopBack)) continue;
        const auto entries = iface.addressEntries();
        for (const QNetworkAddressEntry& entry : entries) {
            const QHostAddress addr = entry.ip();
            if (addr.protocol() != QAbstractSocket::IPv4Protocol) continue;
            if (addr.isLoopback()) continue;
            const QString s = addr.toString();
            if (s.startsWith(QLatin1String("192.168."))
                || s.startsWith(QLatin1String("10."))
                || s.startsWith(QLatin1String("172."))) {
                return QStringLiteral("http://%1:%2").arg(s).arg(port);
            }
            if (fallback.isEmpty()) fallback = s;
        }
    }
    if (!fallback.isEmpty())
        return QStringLiteral("http://%1:%2").arg(fallback).arg(port);
    return QStringLiteral("http://localhost:%1").arg(port);
}

// The single-page app served at "/". Deliberately ES5 — no fetch(), no
// arrow functions, no async/await — because TV browsers can be ancient
// forks. It polls /state and flips between an <img> MJPEG view and a
// native <video>. The <video> autoplay falls back to muted playback if
// the browser blocks autoplay-with-audio; <controls> is the final safety
// net so a stuck video can always be started from the TV remote.
QByteArray castPageHtml()
{
    return QByteArrayLiteral(
R"HTML(<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Crater</title>
<style>
  html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden;}
  #mj,#vid{position:absolute;top:0;left:0;width:100%;height:100%;
    border:0;background:#000;object-fit:contain;}
  #vid{display:none;}
</style>
</head>
<body>
<img id="mj" alt="">
<video id="vid" autoplay loop playsinline controls></video>
<script>
(function(){
  var img=document.getElementById('mj');
  var vid=document.getElementById('vid');
  var cur={mode:null,nonce:null};
  function showVideo(s){
    if(cur.mode==='video'&&cur.nonce===s.nonce){return;}
    img.removeAttribute('src');
    img.style.display='none';
    vid.style.display='block';
    vid.src='/video?n='+encodeURIComponent(s.nonce);
    vid.load();
    var p=vid.play();
    if(p&&p['catch']){p['catch'](function(){vid.muted=true;vid.play();});}
  }
  function showStream(){
    if(cur.mode==='mjpeg'){return;}
    try{vid.pause();}catch(e){}
    vid.removeAttribute('src');
    try{vid.load();}catch(e){}
    vid.style.display='none';
    img.style.display='block';
    img.src='/stream?t='+(new Date()).getTime();
  }
  function apply(s){
    if(s&&s.mode==='video'&&s.nonce!=null){
      showVideo(s);cur={mode:'video',nonce:s.nonce};
    }else{
      showStream();cur={mode:'mjpeg',nonce:null};
    }
  }
  function poll(){
    var x=new XMLHttpRequest();
    x.open('GET','/state',true);
    x.onreadystatechange=function(){
      if(x.readyState===4&&x.status===200){
        try{apply(JSON.parse(x.responseText));}catch(e){}
      }
    };
    try{x.send();}catch(e){}
  }
  setInterval(poll,800);
  poll();
})();
</script>
</body>
</html>
)HTML");
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────
// Impl
// ─────────────────────────────────────────────────────────────────────────
struct BrowserCastService::Impl
{
    BrowserCastService* q          = nullptr;
    ProjectionService*  projection = nullptr;

    QPointer<QQuickItem> sourceItem;
    QTcpServer*          server    = nullptr;
    quint16              port      = 0;
    QString              url;

    // ── MJPEG capture ───────────────────────────────────────────────────
    QTimer        grabTimer;
    bool          grabPending = false;
    QElapsedTimer grabStarted;
    QByteArray    lastJpeg;        // most recent encoded frame
    QElapsedTimer sinceLastPush;   // throttles keepalive resend of static frames
    QList<QTcpSocket*> streamClients;
    bool          lastActive  = false;

    // ── Video mode ──────────────────────────────────────────────────────
    // `videoEpoch` bumps whenever the resolved video path changes, so the
    // page's <video> reloads only when the underlying file actually changes.
    int     videoEpoch       = 0;
    QString currentVideoPath;

    // ── Per-connection bookkeeping ──────────────────────────────────────
    QHash<QTcpSocket*, QByteArray> requestBuffers;  // accumulate until headers complete
    QSet<QTcpSocket*>              handled;         // request already dispatched
    // Active /video transfers — a file + remaining bytes, pumped on
    // bytesWritten so a multi-hundred-MB video never loads fully into RAM.
    struct VideoPump { QFile* file = nullptr; qint64 remaining = 0; };
    QHash<QTcpSocket*, VideoPump>  pumps;

    explicit Impl(BrowserCastService* owner) : q(owner) {}

    // ── lifecycle ───────────────────────────────────────────────────────
    void onNewConnection();
    void onReadyRead(QTcpSocket* socket);
    void onDisconnected(QTcpSocket* socket);
    void cleanupSocket(QTcpSocket* socket);

    // ── request dispatch ────────────────────────────────────────────────
    void dispatch(QTcpSocket* socket, const QByteArray& request);
    void serveRoot(QTcpSocket* socket);
    void serveState(QTcpSocket* socket);
    void serveStream(QTcpSocket* socket);
    void serveVideo(QTcpSocket* socket, const QByteArray& request);
    void serveNotFound(QTcpSocket* socket);
    static void writeSimple(QTcpSocket* socket, const char* status,
                            const QByteArray& contentType, const QByteArray& body);

    // ── MJPEG frame production ──────────────────────────────────────────
    void captureTick();
    void onGrabReady(const QSharedPointer<QQuickItemGrabResult>& result);
    void pushFrame(const QByteArray& jpeg);
    static QByteArray framePart(const QByteArray& jpeg);

    // ── video pumping ───────────────────────────────────────────────────
    void pumpVideo(QTcpSocket* socket);

    // ── state ───────────────────────────────────────────────────────────
    QString resolveVideoPath() const;
    void    refreshVideoState();
    void    updateActive();
};

// ── connection handling ─────────────────────────────────────────────────

void BrowserCastService::Impl::onNewConnection()
{
    while (server && server->hasPendingConnections()) {
        QTcpSocket* socket = server->nextPendingConnection();
        if (!socket) break;
        QObject::connect(socket, &QTcpSocket::readyRead, q,
                         [this, socket] { onReadyRead(socket); });
        QObject::connect(socket, &QTcpSocket::disconnected, q,
                         [this, socket] { onDisconnected(socket); });
    }
}

void BrowserCastService::Impl::onReadyRead(QTcpSocket* socket)
{
    // One request per socket — every response sets Connection: close (or is a
    // long-lived stream). Once dispatched, drain and ignore further bytes.
    if (handled.contains(socket)) {
        socket->readAll();
        return;
    }
    QByteArray& buf = requestBuffers[socket];
    buf += socket->readAll();
    const int headerEnd = buf.indexOf("\r\n\r\n");
    if (headerEnd < 0) {
        if (buf.size() > 16 * 1024) {           // runaway / non-HTTP client
            socket->disconnectFromHost();
        }
        return;
    }
    handled.insert(socket);
    const QByteArray request = buf.left(headerEnd);
    dispatch(socket, request);
}

void BrowserCastService::Impl::onDisconnected(QTcpSocket* socket)
{
    cleanupSocket(socket);
    socket->deleteLater();
}

void BrowserCastService::Impl::cleanupSocket(QTcpSocket* socket)
{
    requestBuffers.remove(socket);
    handled.remove(socket);
    if (pumps.contains(socket)) {
        VideoPump pump = pumps.take(socket);
        delete pump.file;
    }
    if (streamClients.removeOne(socket)) {
        if (streamClients.isEmpty())
            grabTimer.stop();
        updateActive();
    }
}

// ── request dispatch ────────────────────────────────────────────────────

void BrowserCastService::Impl::dispatch(QTcpSocket* socket,
                                        const QByteArray& request)
{
    // Request line: "GET /path?query HTTP/1.1"
    const int firstEol = request.indexOf("\r\n");
    const QByteArray requestLine = (firstEol < 0) ? request : request.left(firstEol);
    const QList<QByteArray> parts = requestLine.split(' ');
    if (parts.size() < 2 || parts[0] != "GET") {
        writeSimple(socket, "405 Method Not Allowed", "text/plain", "GET only");
        socket->disconnectFromHost();
        return;
    }
    const QByteArray target = parts[1];
    const int queryPos = target.indexOf('?');
    const QByteArray path = (queryPos < 0) ? target : target.left(queryPos);

    if (path == "/" || path == "/index.html") {
        serveRoot(socket);
    } else if (path == "/state") {
        serveState(socket);
    } else if (path == "/stream") {
        serveStream(socket);                    // long-lived, no disconnect here
    } else if (path == "/video") {
        serveVideo(socket, request);            // long-lived, no disconnect here
    } else {
        serveNotFound(socket);
    }
}

void BrowserCastService::Impl::writeSimple(QTcpSocket* socket,
                                           const char* status,
                                           const QByteArray& contentType,
                                           const QByteArray& body)
{
    QByteArray response;
    response += "HTTP/1.1 ";
    response += status;
    response += "\r\n";
    response += "Content-Type: " + contentType + "\r\n";
    response += "Content-Length: " + QByteArray::number(body.size()) + "\r\n";
    response += "Cache-Control: no-cache, no-store, must-revalidate\r\n";
    response += "Connection: close\r\n\r\n";
    response += body;
    socket->write(response);
}

void BrowserCastService::Impl::serveRoot(QTcpSocket* socket)
{
    writeSimple(socket, "200 OK", "text/html; charset=utf-8", castPageHtml());
    socket->disconnectFromHost();
}

void BrowserCastService::Impl::serveState(QTcpSocket* socket)
{
    const QString videoPath = resolveVideoPath();
    QByteArray json;
    if (videoPath.isEmpty()) {
        json = "{\"mode\":\"mjpeg\"}";
    } else {
        json = "{\"mode\":\"video\",\"nonce\":"
             + QByteArray::number(videoEpoch) + "}";
    }
    writeSimple(socket, "200 OK", "application/json", json);
    socket->disconnectFromHost();
}

void BrowserCastService::Impl::serveNotFound(QTcpSocket* socket)
{
    writeSimple(socket, "404 Not Found", "text/plain", "Not found");
    socket->disconnectFromHost();
}

void BrowserCastService::Impl::serveStream(QTcpSocket* socket)
{
    QByteArray header;
    header += "HTTP/1.1 200 OK\r\n";
    header += "Content-Type: multipart/x-mixed-replace; boundary=craterframe\r\n";
    header += "Cache-Control: no-cache, no-store, must-revalidate\r\n";
    header += "Pragma: no-cache\r\n";
    header += "Connection: close\r\n\r\n";
    socket->write(header);

    streamClients.append(socket);
    // Push whatever we last rendered immediately, so the TV shows a picture
    // within a frame rather than waiting on the first capture tick.
    if (!lastJpeg.isEmpty())
        socket->write(framePart(lastJpeg));
    if (!grabTimer.isActive())
        grabTimer.start();
    updateActive();
}

void BrowserCastService::Impl::serveVideo(QTcpSocket* socket,
                                          const QByteArray& request)
{
    const QString videoPath = resolveVideoPath();
    if (videoPath.isEmpty() || !QFileInfo::exists(videoPath)) {
        serveNotFound(socket);
        return;
    }
    auto* file = new QFile(videoPath);
    if (!file->open(QIODevice::ReadOnly)) {
        delete file;
        writeSimple(socket, "500 Internal Server Error", "text/plain",
                    "Cannot open video");
        socket->disconnectFromHost();
        return;
    }
    const qint64 size = file->size();

    // Parse a Range header if present. <video> elements rely on Range both
    // to seek and to read an mp4 'moov' atom that sits at the end of the
    // file — without 206 support, non-faststart mp4s often won't play.
    qint64 start = 0;
    qint64 end   = size - 1;
    bool   isRange = false;
    {
        const int rIdx = request.indexOf("\r\nRange:");
        if (rIdx >= 0) {
            int lineEnd = request.indexOf("\r\n", rIdx + 2);
            if (lineEnd < 0) lineEnd = request.size();
            QByteArray value = request.mid(rIdx + 8, lineEnd - (rIdx + 8)).trimmed();
            if (value.startsWith("bytes=")) {
                value = value.mid(6);
                const int dash = value.indexOf('-');
                if (dash >= 0) {
                    const QByteArray a = value.left(dash).trimmed();
                    const QByteArray b = value.mid(dash + 1).trimmed();
                    if (a.isEmpty() && !b.isEmpty()) {
                        // suffix range "bytes=-N" → last N bytes
                        const qint64 n = b.toLongLong();
                        start = qMax<qint64>(0, size - n);
                        end   = size - 1;
                    } else {
                        start = a.toLongLong();
                        end   = b.isEmpty() ? size - 1 : b.toLongLong();
                    }
                    isRange = true;
                }
            }
        }
    }
    start = qBound<qint64>(0, start, qMax<qint64>(0, size - 1));
    end   = qBound<qint64>(start, end, size - 1);
    const qint64 length = (size == 0) ? 0 : (end - start + 1);

    QByteArray header;
    if (isRange) {
        header += "HTTP/1.1 206 Partial Content\r\n";
        header += "Content-Range: bytes " + QByteArray::number(start) + "-"
                + QByteArray::number(end) + "/" + QByteArray::number(size) + "\r\n";
    } else {
        header += "HTTP/1.1 200 OK\r\n";
    }
    header += "Content-Type: " + mimeForVideo(videoPath) + "\r\n";
    header += "Content-Length: " + QByteArray::number(length) + "\r\n";
    header += "Accept-Ranges: bytes\r\n";
    header += "Cache-Control: no-cache\r\n";
    header += "Connection: close\r\n\r\n";
    socket->write(header);

    file->seek(start);
    VideoPump pump;
    pump.file      = file;
    pump.remaining = length;
    pumps.insert(socket, pump);

    // Pump driven by bytesWritten: keep the socket's send buffer topped up
    // without ever holding more than a couple of chunks in memory.
    QObject::connect(socket, &QTcpSocket::bytesWritten, q,
                     [this, socket] { pumpVideo(socket); });
    pumpVideo(socket);
}

void BrowserCastService::Impl::pumpVideo(QTcpSocket* socket)
{
    auto it = pumps.find(socket);
    if (it == pumps.end()) return;
    VideoPump& pump = it.value();

    while (pump.remaining > 0 && socket->bytesToWrite() < kVideoChunkBytes * 2) {
        const qint64 want = qMin(kVideoChunkBytes, pump.remaining);
        const QByteArray chunk = pump.file->read(want);
        if (chunk.isEmpty()) {                  // unexpected EOF / read error
            pump.remaining = 0;
            break;
        }
        socket->write(chunk);
        pump.remaining -= chunk.size();
    }
    if (pump.remaining <= 0) {
        delete pump.file;
        pumps.erase(it);
        socket->disconnectFromHost();
    }
}

// ── MJPEG frame production ──────────────────────────────────────────────

void BrowserCastService::Impl::captureTick()
{
    if (streamClients.isEmpty()) {              // nobody watching — idle
        grabTimer.stop();
        return;
    }
    if (grabPending) {
        // Watchdog: a grab whose ready() never fired (e.g. the projection
        // window briefly stopped rendering) must not wedge capture forever.
        if (grabStarted.isValid() && grabStarted.elapsed() > kGrabWatchdogMs)
            grabPending = false;
        else
            return;
    }
    if (!sourceItem || !sourceItem->window())
        return;

    const QSharedPointer<QQuickItemGrabResult> result = sourceItem->grabToImage();
    if (!result)
        return;
    grabPending = true;
    grabStarted.restart();
    // SingleShotConnection auto-disconnects after ready() fires once. That
    // matters: the lambda captures `result` (the grab's only owner), so the
    // connection must be torn down to release it — otherwise the result
    // object leaks one per captured frame.
    QObject::connect(result.data(), &QQuickItemGrabResult::ready, q,
                     [this, result] { onGrabReady(result); },
                     Qt::SingleShotConnection);
}

void BrowserCastService::Impl::onGrabReady(
    const QSharedPointer<QQuickItemGrabResult>& result)
{
    grabPending = false;
    QImage image = result->image();
    if (image.isNull())
        return;

    // Downscale (aspect-preserving) so the encoded frame is TV-browser- and
    // bandwidth-friendly regardless of the theme's canvas dimensions.
    if (image.width() > kMaxFrameWidth || image.height() > kMaxFrameHeight) {
        image = image.scaled(kMaxFrameWidth, kMaxFrameHeight,
                              Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }

    QByteArray jpeg;
    QBuffer buffer(&jpeg);
    buffer.open(QIODevice::WriteOnly);
    if (!image.save(&buffer, "JPEG", kJpegQuality))
        return;
    pushFrame(jpeg);
}

QByteArray BrowserCastService::Impl::framePart(const QByteArray& jpeg)
{
    QByteArray part;
    part += "--craterframe\r\n";
    part += "Content-Type: image/jpeg\r\n";
    part += "Content-Length: " + QByteArray::number(jpeg.size()) + "\r\n\r\n";
    part += jpeg;
    part += "\r\n";
    return part;
}

void BrowserCastService::Impl::pushFrame(const QByteArray& jpeg)
{
    // Static slide optimisation: if the frame is byte-identical to the last
    // one, only resend it occasionally (keepalive) so an unchanging slide
    // costs ~1 fps of bandwidth instead of 12.
    const bool changed = (jpeg != lastJpeg);
    const qint64 since = sinceLastPush.isValid() ? sinceLastPush.elapsed()
                                                 : (kKeepAliveMs + 1);
    if (!changed && since < kKeepAliveMs)
        return;

    lastJpeg = jpeg;
    sinceLastPush.restart();
    const QByteArray part = framePart(jpeg);

    for (QTcpSocket* client : std::as_const(streamClients)) {
        if (client->state() != QAbstractSocket::ConnectedState)
            continue;
        // Skip a backed-up client for this frame rather than letting its
        // send buffer grow without bound.
        if (client->bytesToWrite() > kSlowClientLimit)
            continue;
        client->write(part);
    }
}

// ── state ───────────────────────────────────────────────────────────────

QString BrowserCastService::Impl::resolveVideoPath() const
{
    if (!projection)
        return {};
    // Logo background takes visual precedence over content (it overlays the
    // whole scene), so check it first — same precedence as ProjectionScene.
    if (projection->showLogo()
        && projection->logoBgKind() == QLatin1String("video")) {
        const QString p = projection->logoBgPath();
        if (!p.isEmpty() && QFileInfo::exists(p))
            return p;
    }
    if (projection->contentKind() == QLatin1String("video")
        && !projection->isClear()) {
        const QString p = projection->currentItem()
                               .value(QStringLiteral("mediaPath")).toString();
        if (!p.isEmpty() && QFileInfo::exists(p))
            return p;
    }
    return {};
}

void BrowserCastService::Impl::refreshVideoState()
{
    const QString resolved = resolveVideoPath();
    if (resolved != currentVideoPath) {
        currentVideoPath = resolved;
        ++videoEpoch;       // page reloads <video> on the next /state poll
    }
}

void BrowserCastService::Impl::updateActive()
{
    const bool nowActive = !streamClients.isEmpty();
    if (nowActive != lastActive) {
        lastActive = nowActive;
        emit q->activeChanged();
    }
}

// ─────────────────────────────────────────────────────────────────────────
// BrowserCastService
// ─────────────────────────────────────────────────────────────────────────
BrowserCastService::BrowserCastService(ProjectionService* projection,
                                       QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>(this))
{
    m_impl->projection = projection;
    m_impl->grabTimer.setInterval(kGrabIntervalMs);
    connect(&m_impl->grabTimer, &QTimer::timeout, this,
            [this] { m_impl->captureTick(); });

    // The page's /state poll already picks up video-mode changes; recomputing
    // the epoch here just means the change is ready the instant it polls.
    if (projection) {
        connect(projection, &ProjectionService::stateChanged, this,
                [this] { m_impl->refreshVideoState(); });
        connect(projection, &ProjectionService::logoBgPathChanged, this,
                [this] { m_impl->refreshVideoState(); });
        connect(projection, &ProjectionService::logoBgKindChanged, this,
                [this] { m_impl->refreshVideoState(); });
    }
}

BrowserCastService::~BrowserCastService()
{
    stop();
}

bool BrowserCastService::listening() const
{
    return m_impl->server && m_impl->server->isListening();
}

QString BrowserCastService::url() const
{
    return listening() ? m_impl->url : QString();
}

bool BrowserCastService::active() const
{
    return m_impl->lastActive;
}

void BrowserCastService::setSourceItem(QQuickItem* item)
{
    m_impl->sourceItem = item;
}

bool BrowserCastService::start()
{
    if (listening())
        return true;

    if (!m_impl->server) {
        m_impl->server = new QTcpServer(this);
        connect(m_impl->server, &QTcpServer::newConnection, this,
                [this] { m_impl->onNewConnection(); });
    }

    // Listen on every IPv4 interface — the TV is a separate device, so the
    // server must be reachable on the LAN address (loopback-only would be
    // useless here). This is a temporary, display-only, read-only server on
    // a trusted church LAN; it is a deliberate, scoped exception to
    // ARCHITECTURE.md §5.2's "bind to LAN, never 0.0.0.0" guidance.
    for (const quint16 candidate : kPortCandidates) {
        if (m_impl->server->listen(QHostAddress::AnyIPv4, candidate)) {
            m_impl->port = candidate;
            m_impl->url  = detectLanUrl(candidate);
            qInfo().noquote()
                << "BrowserCast: serving projection at" << m_impl->url
                << "— open this URL in the TV browser";
            emit listeningChanged();
            return true;
        }
    }
    qWarning() << "BrowserCast: could not bind any candidate port — feature off";
    return false;
}

void BrowserCastService::stop()
{
    m_impl->grabTimer.stop();

    // Close every live connection; cleanupSocket frees any in-flight video
    // file handle. Copy first — cleanup mutates the container.
    const auto pumpSockets = m_impl->pumps.keys();
    for (QTcpSocket* socket : pumpSockets) {
        m_impl->cleanupSocket(socket);
        socket->abort();
        socket->deleteLater();
    }
    const auto streamSockets = m_impl->streamClients;
    for (QTcpSocket* socket : streamSockets) {
        m_impl->cleanupSocket(socket);
        socket->abort();
        socket->deleteLater();
    }
    m_impl->streamClients.clear();
    m_impl->requestBuffers.clear();
    m_impl->handled.clear();

    if (m_impl->server) {
        m_impl->server->close();
        emit listeningChanged();
    }
    m_impl->updateActive();
}

}  // namespace crater
