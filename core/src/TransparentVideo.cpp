#include "crater/TransparentVideo.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QLibrary>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QThread>
#include <QtEndian>

#include <cstring>
#include <vector>

// FFmpeg's public headers are C. Only their declarations and struct layouts
// are used: every function is called through a pointer resolved at run time.
#ifndef __STDC_CONSTANT_MACROS
#  define __STDC_CONSTANT_MACROS
#endif
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
}

namespace crater::transparentvideo {

namespace {

// ── FFmpeg, resolved at run time ────────────────────────────────────────

#define CRATER_FFMPEG_FUNCTIONS(X)                                           \
    X(avutil,   avutil_version)                                              \
    X(avutil,   av_frame_alloc)                                              \
    X(avutil,   av_frame_free)                                               \
    X(avutil,   av_frame_get_buffer)                                         \
    X(avutil,   av_frame_unref)                                              \
    X(avutil,   av_dict_get)                                                 \
    X(avutil,   av_opt_set_int)                                              \
    X(avutil,   av_strerror)                                                 \
    X(avcodec,  avcodec_version)                                             \
    X(avcodec,  avcodec_find_decoder)                                        \
    X(avcodec,  avcodec_find_encoder)                                        \
    X(avcodec,  avcodec_alloc_context3)                                      \
    X(avcodec,  avcodec_free_context)                                        \
    X(avcodec,  avcodec_parameters_to_context)                               \
    X(avcodec,  avcodec_parameters_from_context)                             \
    X(avcodec,  avcodec_parameters_copy)                                     \
    X(avcodec,  avcodec_open2)                                               \
    X(avcodec,  avcodec_send_packet)                                         \
    X(avcodec,  avcodec_receive_packet)                                      \
    X(avcodec,  avcodec_send_frame)                                          \
    X(avcodec,  avcodec_receive_frame)                                       \
    X(avcodec,  av_packet_alloc)                                             \
    X(avcodec,  av_packet_free)                                              \
    X(avcodec,  av_packet_unref)                                             \
    X(avcodec,  av_packet_get_side_data)                                     \
    X(avcodec,  av_packet_side_data_get)                                     \
    X(avcodec,  av_packet_side_data_new)                                     \
    X(avcodec,  av_packet_rescale_ts)                                        \
    X(avcodec,  av_new_packet)                                               \
    X(avformat, avformat_version)                                            \
    X(avformat, avformat_open_input)                                         \
    X(avformat, avformat_find_stream_info)                                   \
    X(avformat, av_find_best_stream)                                         \
    X(avformat, av_guess_frame_rate)                                         \
    X(avformat, av_guess_sample_aspect_ratio)                                \
    X(avformat, av_read_frame)                                               \
    X(avformat, avformat_close_input)                                        \
    X(avformat, avformat_alloc_output_context2)                              \
    X(avformat, avformat_new_stream)                                         \
    X(avformat, avformat_free_context)                                       \
    X(avformat, avformat_write_header)                                       \
    X(avformat, av_interleaved_write_frame)                                  \
    X(avformat, av_write_trailer)                                            \
    X(avformat, avio_open)                                                   \
    X(avformat, avio_closep)                                                 \
    X(swscale,  swscale_version)                                             \
    X(swscale,  sws_getContext)                                              \
    X(swscale,  sws_freeContext)                                             \
    X(swscale,  sws_scale)                                                   \
    X(swscale,  sws_setColorspaceDetails)                                    \
    X(swscale,  sws_getCoefficients)

struct Api {
    bool ok = false;
#define CRATER_DECLARE(lib, name) decltype(&::name) name = nullptr;
    CRATER_FFMPEG_FUNCTIONS(CRATER_DECLARE)
#undef CRATER_DECLARE
};

// Qt's FFmpeg sits next to the executable on Windows (the loader looks
// there first), in usr/lib of the AppImage and in Contents/Frameworks of
// the macOS bundle. QLibrary adds the platform's prefix, suffix and
// version: avcodec-61.dll, libavcodec.so.61, libavcodec.61.dylib.
bool loadLibrary(QLibrary& lib, const char* name, int major)
{
#ifdef Q_OS_WIN
    lib.setFileName(QStringLiteral("%1-%2").arg(QLatin1String(name)).arg(major));
    return lib.load();
#else
    // The app's own folders before the system's, so a distro FFmpeg of the
    // same major version is never mixed with Qt's.
    const QString appDir = QCoreApplication::applicationDirPath();
    const QStringList dirs = {
        appDir + QStringLiteral("/../lib/"),
        appDir + QStringLiteral("/../Frameworks/"),
        appDir + QLatin1Char('/'),
        QString(),
    };
    for (const QString& dir : dirs) {
        lib.setFileNameAndVersion(dir + QLatin1String(name), major);
        if (lib.load()) return true;
    }
    return false;
#endif
}

Api loadApi()
{
    // Never unloaded: Qt Multimedia holds the same libraries for the
    // process's lifetime anyway.
    static QLibrary avutil, avcodec, avformat, swscale;
    Api api;
    const struct { QLibrary& lib; const char* name; int major; } libs[] = {
        { avutil,   "avutil",   LIBAVUTIL_VERSION_MAJOR },
        { avcodec,  "avcodec",  LIBAVCODEC_VERSION_MAJOR },
        { avformat, "avformat", LIBAVFORMAT_VERSION_MAJOR },
        { swscale,  "swscale",  LIBSWSCALE_VERSION_MAJOR },
    };
    for (const auto& l : libs) {
        if (!loadLibrary(l.lib, l.name, l.major)) {
            qInfo().noquote() << "TransparentVideo: no" << l.name << l.major
                              << "library, transparent WebM stays off:" << l.lib.errorString();
            return api;
        }
    }

#define CRATER_RESOLVE(lib, name)                                                    \
    api.name = reinterpret_cast<decltype(api.name)>(lib.resolve(#name));             \
    if (!api.name) {                                                                 \
        qWarning() << "TransparentVideo: FFmpeg has no" << #name;                    \
        return api;                                                                  \
    }
    CRATER_FFMPEG_FUNCTIONS(CRATER_RESOLVE)
#undef CRATER_RESOLVE

    // The struct layouts come from the headers, so a different major
    // version can't be trusted with them.
    const bool sameVersions =
        AV_VERSION_MAJOR(api.avutil_version())   == LIBAVUTIL_VERSION_MAJOR
        && AV_VERSION_MAJOR(api.avcodec_version())  == LIBAVCODEC_VERSION_MAJOR
        && AV_VERSION_MAJOR(api.avformat_version()) == LIBAVFORMAT_VERSION_MAJOR
        && AV_VERSION_MAJOR(api.swscale_version())  == LIBSWSCALE_VERSION_MAJOR;
    if (!sameVersions) {
        qWarning() << "TransparentVideo: FFmpeg versions don't match the headers, staying off";
        return api;
    }
    api.ok = true;
    return api;
}

const Api& ffmpeg()
{
    static const Api api = loadApi();
    return api;
}

QString errorText(int code)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {};
    ffmpeg().av_strerror(code, buf, sizeof buf);
    return QString::fromUtf8(buf);
}

// ── Limits ──────────────────────────────────────────────────────────────

// About 30 s of 1080p at 30 fps, counted in pixels x frames. A logo or a
// lower third is far below it. A full-length clip would take minutes and
// gigabytes.
constexpr qint64 kMaxPixelFrames = qint64(1920) * 1080 * 30 * 30;
// What the cache folder is trimmed to after each new copy.
constexpr qint64 kCacheLimit = qint64(2) << 30;
// Free space a conversion leaves on the disk. It doesn't start when its
// estimated size would cut into this, and stops when the disk gets within
// half of it.
constexpr qint64 kDiskReserve = qint64(512) << 20;

// PNG of overlay art comes to 2 to 5 percent of raw RGBA. Estimates use 10.
qint64 estimatedBytes(qint64 pixelFrames)
{
    return pixelFrames * 4 / 10;
}

// Half the cores, at most four, for each codec. The conversion usually runs
// while a service is live, beside the playback it must not starve.
int codecThreads()
{
    return qBound(1, QThread::idealThreadCount() / 2, 4);
}

// ── Cache ───────────────────────────────────────────────────────────────

QString cacheDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
         + QStringLiteral("/transparent-video");
}

// Keeps the folder under kCacheLimit by dropping the least recently used
// copies (cachedCopy marks use), and clears out parts left by a run that
// was killed. A copy that is playing can't be deleted on Windows, and is
// skipped.
void pruneCache(const QString& keep)
{
    const QDir dir(cacheDir());
    const QDateTime dayAgo = QDateTime::currentDateTimeUtc().addDays(-1);
    for (const QFileInfo& part : dir.entryInfoList({ QStringLiteral("*.part") }, QDir::Files))
        if (part.lastModified() < dayAgo) QFile::remove(part.absoluteFilePath());

    qint64 total = 0;
    const QFileInfoList copies =
        dir.entryInfoList({ QStringLiteral("*.mkv") }, QDir::Files, QDir::Time);   // newest first
    for (const QFileInfo& copy : copies) {
        total += copy.size();
        if (total > kCacheLimit && copy.absoluteFilePath() != keep
            && QFile::remove(copy.absoluteFilePath()))
            total -= copy.size();
    }
}

// ── Conversion ──────────────────────────────────────────────────────────

// Frees everything the conversion opened, whichever step it stopped at.
struct Job {
    const Api& f = ffmpeg();
    AVFormatContext* in = nullptr;
    AVFormatContext* out = nullptr;
    AVCodecContext*  colourDec = nullptr;
    AVCodecContext*  alphaDec = nullptr;
    AVCodecContext*  enc = nullptr;
    SwsContext*      sws = nullptr;
    SwsContext*      alphaSws = nullptr;
    AVPacket*        packet = nullptr;
    AVPacket*        alphaPacket = nullptr;
    AVFrame*         rgba = nullptr;
    AVFrame*         alphaScaled = nullptr;
    int              index = -1;          // the alpha video stream
    std::vector<int> outIndex;            // input stream -> output stream, or -1
    int64_t          frameDuration = 0;   // one frame at the stream's rate, encoder time base

    // The output file has to be closed before it can be renamed.
    void closeOutput()
    {
        if (!out) return;
        if (out->pb) f.avio_closep(&out->pb);
        f.avformat_free_context(out);
        out = nullptr;
    }

    ~Job()
    {
        if (sws) f.sws_freeContext(sws);
        if (alphaSws) f.sws_freeContext(alphaSws);
        f.av_frame_free(&alphaScaled);
        f.av_frame_free(&rgba);
        f.av_packet_free(&alphaPacket);
        f.av_packet_free(&packet);
        f.avcodec_free_context(&enc);
        f.avcodec_free_context(&alphaDec);
        f.avcodec_free_context(&colourDec);
        closeOutput();
        if (in) f.avformat_close_input(&in);
    }
};

// The video stream, when it is VP8/VP9 flagged with an alpha side stream.
// Matroska marks it with AlphaMode, which FFmpeg's demuxer reports as the
// stream tag "alpha_mode".
int alphaStreamIndex(const Api& f, AVFormatContext* in)
{
    const int index = f.av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (index < 0) return -1;
    const AVStream* st = in->streams[index];
    const AVCodecID codec = st->codecpar->codec_id;
    if (codec != AV_CODEC_ID_VP8 && codec != AV_CODEC_ID_VP9) return -1;
    const AVDictionaryEntry* tag = f.av_dict_get(st->metadata, "alpha_mode", nullptr, 0);
    return tag && std::strcmp(tag->value, "1") == 0 ? index : -1;
}

AVCodecContext* openDecoder(const Api& f, const AVStream* st)
{
    const AVCodec* codec = f.avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return nullptr;
    AVCodecContext* ctx = f.avcodec_alloc_context3(codec);
    if (!ctx) return nullptr;
    if (f.avcodec_parameters_to_context(ctx, st->codecpar) < 0) {
        f.avcodec_free_context(&ctx);
        return nullptr;
    }
    // Slice threads only. Frame threads hold frames back, and each colour
    // frame has to meet the alpha frame decoded from the same packet.
    ctx->thread_type  = FF_THREAD_SLICE;
    ctx->thread_count = codecThreads();
    if (f.avcodec_open2(ctx, codec, nullptr) < 0) f.avcodec_free_context(&ctx);
    return ctx;
}

// Every frame the decoder has ready after the last send.
std::vector<AVFrame*> drain(const Api& f, AVCodecContext* dec)
{
    std::vector<AVFrame*> frames;
    for (;;) {
        AVFrame* frame = f.av_frame_alloc();
        if (!frame || f.avcodec_receive_frame(dec, frame) < 0) {
            f.av_frame_free(&frame);
            return frames;
        }
        frames.push_back(frame);
    }
}

void freeFrames(const Api& f, std::vector<AVFrame*>& frames)
{
    for (AVFrame*& frame : frames) f.av_frame_free(&frame);
    frames.clear();
}

// libvpx encodes alpha as 8-bit 4:2:0. Its luma plane is the alpha, so any
// 8-bit planar YUV (or grey) frame can be read the same way. Anything else
// counts as no alpha for that frame.
bool readableAlpha(int format)
{
    switch (format) {
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P:
    case AV_PIX_FMT_YUV422P:
    case AV_PIX_FMT_YUV444P:
    case AV_PIX_FMT_GRAY8:
        return true;
    default:
        return false;
    }
}

// Writes the alpha plane (libvpx carries alpha as the luma of the side
// stream, full range) into the RGBA frame's alpha bytes. With no plane the
// picture stays opaque.
//
// Then gives every fully transparent pixel the colour of an opaque
// neighbour. The encoder left white (or anything) there, and when the video
// is scaled, filtering blends that colour into the edge as a fringe. Pixels
// with no visible neighbour go black, which also compresses better.
void applyAlpha(AVFrame* rgba, const uint8_t* alpha, int alphaStride)
{
    const int w = rgba->width, h = rgba->height;
    uint8_t* base = rgba->data[0];
    const int stride = rgba->linesize[0];
    for (int y = 0; y < h; ++y) {
        uint8_t* row = base + y * stride;
        const uint8_t* a = alpha ? alpha + y * alphaStride : nullptr;
        for (int x = 0; x < w; ++x) row[x * 4 + 3] = a ? a[x] : 255;
    }
    if (!alpha) return;

    for (int y = 0; y < h; ++y) {
        uint8_t* row = base + y * stride;
        for (int x = 0; x < w; ++x) {
            uint8_t* px = row + x * 4;
            if (px[3] != 0) continue;
            const uint8_t* from = nullptr;
            if (x > 0 && px[-1] != 0)                         from = px - 4;
            else if (x + 1 < w && px[7] != 0)                 from = px + 4;
            else if (y > 0 && px[3 - stride] != 0)            from = px - stride;
            else if (y + 1 < h && px[3 + stride] != 0)        from = px + stride;
            px[0] = from ? from[0] : 0;
            px[1] = from ? from[1] : 0;
            px[2] = from ? from[2] : 0;
        }
    }
}

bool writePackets(Job& job, QString* error)
{
    const Api& f = job.f;
    AVPacket* pkt = job.packet;
    AVStream* outSt = job.out->streams[job.outIndex[job.index]];
    for (;;) {
        const int r = f.avcodec_receive_packet(job.enc, pkt);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return true;
        if (r < 0) {
            *error = QStringLiteral("encode: ") + errorText(r);
            return false;
        }
        // WebM blocks rarely carry a duration, and the frame-threaded
        // encoder doesn't fill one in. Without it the copy's last frame has
        // no length and a looping logo skips it.
        if (pkt->duration <= 0) pkt->duration = job.frameDuration;
        f.av_packet_rescale_ts(pkt, job.enc->time_base, outSt->time_base);
        pkt->stream_index = outSt->index;
        if (const int w = f.av_interleaved_write_frame(job.out, pkt); w < 0) {
            *error = QStringLiteral("write: ") + errorText(w);
            return false;
        }
    }
}

// Decodes job.in's alpha stream into the copy at dstPath. Returns Copy when
// the file is complete.
Result convert(Job& job, const QString& dstPath, const std::atomic_bool* cancel, QString* error)
{
    const Api& f = job.f;
    const auto fail = [&](const QString& why, int code = 0) {
        *error = code ? why + QStringLiteral(": ") + errorText(code) : why;
        return Result::Failed;
    };
    AVStream* inSt = job.in->streams[job.index];

    job.colourDec = openDecoder(f, inSt);
    if (!job.colourDec) return fail(QStringLiteral("no colour decoder"));
    job.alphaDec = openDecoder(f, inSt);
    if (!job.alphaDec) return fail(QStringLiteral("no alpha decoder"));

    const int w = inSt->codecpar->width, h = inSt->codecpar->height;
    if (w <= 0 || h <= 0) return fail(QStringLiteral("no picture size"));
    const qint64 pixels = qint64(w) * h;

    // Judged up front when the file says how long it is, and again while
    // decoding for files that don't.
    const AVRational rate = f.av_guess_frame_rate(job.in, inSt, nullptr);
    QStorageInfo disk(QFileInfo(dstPath).absolutePath());
    if (job.in->duration > 0 && rate.num > 0 && rate.den > 0) {
        const qint64 pixelFrames = qint64(double(job.in->duration) / AV_TIME_BASE
                                          * rate.num / rate.den) * pixels;
        if (pixelFrames > kMaxPixelFrames) {
            *error = QStringLiteral("too long");
            return Result::TooLarge;
        }
        if (disk.isValid() && disk.bytesAvailable() - estimatedBytes(pixelFrames) < kDiskReserve)
            return fail(QStringLiteral("not enough free disk space"));
    }

    // PNG in Matroska: lossless, keeps alpha, decodes fast enough for the
    // weak machines Crater targets (frame-threaded in FFmpeg), and takes
    // any audio a WebM can carry as it is.
    const QByteArray dst = dstPath.toUtf8();
    if (int r = f.avformat_alloc_output_context2(&job.out, nullptr, "matroska", dst.constData()); r < 0)
        return fail(QStringLiteral("output"), r);
    const AVCodec* png = f.avcodec_find_encoder(AV_CODEC_ID_PNG);
    if (!png) return fail(QStringLiteral("no PNG encoder"));
    job.enc = f.avcodec_alloc_context3(png);
    if (!job.enc) return fail(QStringLiteral("encoder"));
    const AVRational aspect = f.av_guess_sample_aspect_ratio(job.in, inSt, nullptr);
    job.enc->width     = w;
    job.enc->height    = h;
    job.enc->pix_fmt   = AV_PIX_FMT_RGBA;
    job.enc->time_base = inSt->time_base;
    job.enc->framerate = rate;
    job.enc->sample_aspect_ratio = aspect;
    job.enc->thread_count = codecThreads();
    // zlib level 3 is several times faster than the default for a few
    // percent more size. Mixed row filters win that back on logo art.
    job.enc->compression_level = 3;
    f.av_opt_set_int(job.enc->priv_data, "pred", 5 /* mixed */, 0);
    if (job.out->oformat->flags & AVFMT_GLOBALHEADER)
        job.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (int r = f.avcodec_open2(job.enc, png, nullptr); r < 0)
        return fail(QStringLiteral("open encoder"), r);

    AVStream* outSt = f.avformat_new_stream(job.out, nullptr);
    if (!outSt) return fail(QStringLiteral("output stream"));
    outSt->time_base = job.enc->time_base;
    if (int r = f.avcodec_parameters_from_context(outSt->codecpar, job.enc); r < 0)
        return fail(QStringLiteral("stream parameters"), r);
    outSt->sample_aspect_ratio = aspect;
    // A phone video's rotation.
    if (const AVPacketSideData* rotation = f.av_packet_side_data_get(
            inSt->codecpar->coded_side_data, inSt->codecpar->nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX)) {
        if (AVPacketSideData* copy = f.av_packet_side_data_new(
                &outSt->codecpar->coded_side_data, &outSt->codecpar->nb_coded_side_data,
                AV_PKT_DATA_DISPLAYMATRIX, rotation->size, 0))
            std::memcpy(copy->data, rotation->data, rotation->size);
    }

    job.outIndex.assign(job.in->nb_streams, -1);
    job.outIndex[job.index] = outSt->index;
    for (unsigned i = 0; i < job.in->nb_streams; ++i) {
        const AVStream* audio = job.in->streams[i];
        if (audio->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        AVStream* copy = f.avformat_new_stream(job.out, nullptr);
        if (!copy) return fail(QStringLiteral("audio stream"));
        if (int r = f.avcodec_parameters_copy(copy->codecpar, audio->codecpar); r < 0)
            return fail(QStringLiteral("audio parameters"), r);
        copy->codecpar->codec_tag = 0;
        copy->time_base   = audio->time_base;
        copy->disposition = audio->disposition;
        job.outIndex[i] = copy->index;
    }

    if (int r = f.avio_open(&job.out->pb, dst.constData(), AVIO_FLAG_WRITE); r < 0)
        return fail(QStringLiteral("create file"), r);
    if (int r = f.avformat_write_header(job.out, nullptr); r < 0)
        return fail(QStringLiteral("write header"), r);
    // The muxer may change each stream's time base in the header.
    outSt = job.out->streams[job.outIndex[job.index]];

    job.packet      = f.av_packet_alloc();
    job.alphaPacket = f.av_packet_alloc();
    job.rgba        = f.av_frame_alloc();
    job.alphaScaled = f.av_frame_alloc();
    if (!job.packet || !job.alphaPacket || !job.rgba || !job.alphaScaled)
        return fail(QStringLiteral("out of memory"));

    int64_t lastPts = AV_NOPTS_VALUE;
    int swsFormat = -1, swsW = 0, swsH = 0, alphaW = 0, alphaH = 0;
    const AVRational tb = job.enc->time_base;
    if (rate.num > 0 && rate.den > 0 && tb.num > 0)
        job.frameDuration = qMax<int64_t>(
            1, qRound64(double(tb.den) * rate.den / (double(tb.num) * rate.num)));

    int frames = 0, alphaFrames = 0;
    qint64 pixelFrames = 0;

    // One colour frame with the alpha frame from the same packet, into the
    // encoder.
    const auto encode = [&](AVFrame* colour, const AVFrame* alpha) -> bool {
        if (!job.sws || colour->format != swsFormat || colour->width != swsW
            || colour->height != swsH) {
            if (job.sws) f.sws_freeContext(job.sws);
            job.sws = f.sws_getContext(colour->width, colour->height,
                                       AVPixelFormat(colour->format), w, h, AV_PIX_FMT_RGBA,
                                       SWS_BICUBIC, nullptr, nullptr, nullptr);
            if (!job.sws) {
                *error = QStringLiteral("no colour conversion for this picture");
                return false;
            }
            swsFormat = colour->format; swsW = colour->width; swsH = colour->height;
            // The stream's own colour matrix and range, not swscale's
            // BT.601 limited-range default.
            const int space = colour->colorspace == AVCOL_SPC_UNSPECIFIED
                ? (h >= 720 ? AVCOL_SPC_BT709 : AVCOL_SPC_BT470BG) : colour->colorspace;
            f.sws_setColorspaceDetails(job.sws, f.sws_getCoefficients(space),
                                       colour->color_range == AVCOL_RANGE_JPEG ? 1 : 0,
                                       f.sws_getCoefficients(AVCOL_SPC_BT709), 1,
                                       0, 1 << 16, 1 << 16);
        }
        // The encoder may still hold the last buffer, so take a fresh one.
        f.av_frame_unref(job.rgba);
        job.rgba->width  = w;
        job.rgba->height = h;
        job.rgba->format = AV_PIX_FMT_RGBA;
        if (int r = f.av_frame_get_buffer(job.rgba, 0); r < 0) {
            *error = QStringLiteral("frame buffer: ") + errorText(r);
            return false;
        }
        f.sws_scale(job.sws, colour->data, colour->linesize, 0, colour->height,
                    job.rgba->data, job.rgba->linesize);

        // VP9 can change size mid-stream. The colour was scaled to the
        // copy's size above, and the alpha follows it.
        const uint8_t* plane = nullptr;
        int planeStride = 0;
        if (alpha && readableAlpha(alpha->format)) {
            if (alpha->width == w && alpha->height == h) {
                plane = alpha->data[0];
                planeStride = alpha->linesize[0];
            } else {
                if (!job.alphaSws || alpha->width != alphaW || alpha->height != alphaH) {
                    if (job.alphaSws) f.sws_freeContext(job.alphaSws);
                    job.alphaSws = f.sws_getContext(alpha->width, alpha->height, AV_PIX_FMT_GRAY8,
                                                    w, h, AV_PIX_FMT_GRAY8, SWS_BILINEAR,
                                                    nullptr, nullptr, nullptr);
                    alphaW = alpha->width; alphaH = alpha->height;
                }
                if (!job.alphaScaled->data[0]) {
                    job.alphaScaled->width  = w;
                    job.alphaScaled->height = h;
                    job.alphaScaled->format = AV_PIX_FMT_GRAY8;
                    if (f.av_frame_get_buffer(job.alphaScaled, 0) < 0) f.av_frame_unref(job.alphaScaled);
                }
                if (job.alphaSws && job.alphaScaled->data[0]) {
                    f.sws_scale(job.alphaSws, alpha->data, alpha->linesize, 0, alpha->height,
                                job.alphaScaled->data, job.alphaScaled->linesize);
                    plane = job.alphaScaled->data[0];
                    planeStride = job.alphaScaled->linesize[0];
                }
            }
        }
        if (plane) ++alphaFrames;
        applyAlpha(job.rgba, plane, planeStride);

        int64_t pts = colour->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) pts = lastPts == AV_NOPTS_VALUE ? 0 : lastPts + 1;
        if (lastPts != AV_NOPTS_VALUE && pts <= lastPts) pts = lastPts + 1;
        lastPts = pts;
        job.rgba->pts      = pts;
        job.rgba->duration = colour->duration;
        if (int r = f.avcodec_send_frame(job.enc, job.rgba); r < 0) {
            *error = QStringLiteral("encode: ") + errorText(r);
            return false;
        }
        return writePackets(job, error);
    };

    const auto encodePairs = [&](std::vector<AVFrame*>& colour, std::vector<AVFrame*>& alpha) {
        bool ok = true;
        for (size_t i = 0; ok && i < colour.size(); ++i)
            ok = encode(colour[i], i < alpha.size() ? alpha[i] : nullptr);
        frames      += int(colour.size());
        pixelFrames += qint64(colour.size()) * pixels;
        freeFrames(f, colour);
        freeFrames(f, alpha);
        return ok;
    };

    int badPackets = 0, sinceDiskCheck = 0;
    for (;;) {
        if (cancel && cancel->load(std::memory_order_relaxed)) return Result::Cancelled;
        const int r = f.av_read_frame(job.in, job.packet);
        if (r == AVERROR_EOF) break;
        if (r < 0) return fail(QStringLiteral("read"), r);
        const int stream = job.packet->stream_index;
        const int outStream = stream >= 0 && size_t(stream) < job.outIndex.size()
            ? job.outIndex[size_t(stream)] : -1;
        if (outStream < 0) { f.av_packet_unref(job.packet); continue; }

        // Audio goes straight through.
        if (stream != job.index) {
            AVStream* copy = job.out->streams[outStream];
            f.av_packet_rescale_ts(job.packet, job.in->streams[stream]->time_base, copy->time_base);
            job.packet->stream_index = outStream;
            job.packet->pos = -1;
            if (int wr = f.av_interleaved_write_frame(job.out, job.packet); wr < 0)
                return fail(QStringLiteral("write audio"), wr);
            continue;
        }

        // The side stream rides along as BlockAdditional data: an 8-byte
        // big-endian BlockAddID (1 for alpha), then the VP8/VP9 frame. A
        // block without one shows opaque, as it does in a browser.
        size_t sideSize = 0;
        const uint8_t* side = f.av_packet_get_side_data(
            job.packet, AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL, &sideSize);
        bool haveAlpha = false;
        if (side && sideSize > 8 && qFromBigEndian<quint64>(side) == 1
            && f.av_new_packet(job.alphaPacket, int(sideSize - 8)) == 0) {
            std::memcpy(job.alphaPacket->data, side + 8, sideSize - 8);
            job.alphaPacket->pts   = job.packet->pts;
            job.alphaPacket->dts   = job.packet->dts;
            job.alphaPacket->flags = job.packet->flags;
            haveAlpha = true;
        }

        const int sent = f.avcodec_send_packet(job.colourDec, job.packet);
        f.av_packet_unref(job.packet);
        std::vector<AVFrame*> colour, alpha;
        if (sent >= 0) {
            badPackets = 0;
            colour = drain(f, job.colourDec);
        } else if (sent != AVERROR_INVALIDDATA || ++badPackets > 25) {
            // A damaged frame now and then is skipped, the way Qt's player
            // would. A run of them means the file is broken.
            if (haveAlpha) f.av_packet_unref(job.alphaPacket);
            return fail(QStringLiteral("decode"), sent);
        }
        if (haveAlpha) {
            // Decoded even when its colour frame was lost, so the alpha
            // decoder keeps its reference frames. A damaged alpha frame
            // costs that frame its transparency, not the whole video.
            if (f.avcodec_send_packet(job.alphaDec, job.alphaPacket) >= 0)
                alpha = drain(f, job.alphaDec);
            f.av_packet_unref(job.alphaPacket);
        }
        sinceDiskCheck += int(colour.size());
        if (!encodePairs(colour, alpha)) return Result::Failed;

        if (pixelFrames > kMaxPixelFrames) {
            *error = QStringLiteral("too long");
            return Result::TooLarge;
        }
        // Tagged transparent, but the alpha blocks are gone (some remuxers
        // drop them): the copy would be a big, slow, opaque duplicate.
        if (frames >= 60 && alphaFrames == 0) {
            *error = QStringLiteral("no alpha data");
            return Result::NoAlpha;
        }
        if (sinceDiskCheck >= 30) {
            sinceDiskCheck = 0;
            disk.refresh();
            if (disk.isValid() && disk.bytesAvailable() < kDiskReserve / 2)
                return fail(QStringLiteral("the disk is nearly full"));
        }
    }

    f.avcodec_send_packet(job.colourDec, nullptr);
    f.avcodec_send_packet(job.alphaDec, nullptr);
    std::vector<AVFrame*> colour = drain(f, job.colourDec);
    std::vector<AVFrame*> alpha  = drain(f, job.alphaDec);
    if (!encodePairs(colour, alpha)) return Result::Failed;

    f.avcodec_send_frame(job.enc, nullptr);
    if (!writePackets(job, error)) return Result::Failed;
    if (frames == 0) return fail(QStringLiteral("no frames"));
    if (alphaFrames == 0) {
        *error = QStringLiteral("no alpha data");
        return Result::NoAlpha;
    }
    if (int r = f.av_write_trailer(job.out); r < 0) return fail(QStringLiteral("finish file"), r);
    return Result::Copy;
}

}  // namespace

bool mayCarryAlpha(const QString& path)
{
    const QString suffix = QFileInfo(path).suffix().toLower();
    if (suffix != QLatin1String("webm") && suffix != QLatin1String("mkv")) return false;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return false;
    return file.read(4) == QByteArray("\x1a\x45\xdf\xa3", 4);   // EBML
}

QString copyPath(const QString& path)
{
    const QFileInfo info(path);
    QString absolute = info.absoluteFilePath();
#ifdef Q_OS_WIN
    absolute = absolute.toLower();   // one file, however its name is cased
#endif
    const QByteArray key = absolute.toUtf8() + '|'
        + QByteArray::number(info.size()) + '|'
        + QByteArray::number(info.lastModified().toMSecsSinceEpoch());
    const QString name = QString::fromLatin1(
        QCryptographicHash::hash(key, QCryptographicHash::Sha1).toHex().left(20));
    return cacheDir() + QLatin1Char('/') + name + QStringLiteral(".mkv");
}

QString cachedCopy(const QString& path)
{
    const QString copy = copyPath(path);
    QFile file(copy);
    if (!file.exists()) return {};
    // Recently used, so the cache trim keeps it.
    if (file.open(QIODevice::ReadWrite | QIODevice::ExistingOnly))
        file.setFileTime(QDateTime::currentDateTimeUtc(), QFileDevice::FileModificationTime);
    return copy;
}

Prepared prepare(const QString& path, const std::atomic_bool* cancel)
{
    if (!mayCarryAlpha(path)) return {};
    if (QString copy = cachedCopy(path); !copy.isEmpty()) return { Result::Copy, copy };

    Job job;
    const Api& f = job.f;
    if (!f.ok) return {};

    // Most WebMs have no alpha. The headers say so before any decoding.
    const QByteArray src = path.toUtf8();
    if (f.avformat_open_input(&job.in, src.constData(), nullptr, nullptr) < 0
        || f.avformat_find_stream_info(job.in, nullptr) < 0)
        return {};
    job.index = alphaStreamIndex(f, job.in);
    if (job.index < 0) return {};

    const QString copy = copyPath(path);
    QDir().mkpath(QFileInfo(copy).absolutePath());
    // Written under a name of its own and renamed when complete, so a copy
    // cut short (a crash, a full disk) is never picked up as finished, and
    // two Crater processes on the same file (a relaunch while the old one
    // is still exiting) never write into one file.
    static std::atomic_int runs{ 0 };
    const QString part = copy + QStringLiteral(".%1-%2.part")
        .arg(QCoreApplication::applicationPid()).arg(++runs);

    QElapsedTimer timer;
    timer.start();
    QString error;
    const Result result = convert(job, part, cancel, &error);
    job.closeOutput();
    const QString name = QFileInfo(path).fileName();
    if (result != Result::Copy) {
        QFile::remove(part);
        if (result == Result::Failed)
            qWarning().noquote() << "TransparentVideo:" << name
                                 << QStringLiteral("conversion failed (%1), it plays without transparency").arg(error);
        else if (result == Result::TooLarge)
            qInfo().noquote() << "TransparentVideo:" << name
                              << "is too long for a transparent copy, it plays without transparency";
        else if (result == Result::NoAlpha)
            qInfo().noquote() << "TransparentVideo:" << name
                              << "is tagged transparent but has no alpha data, it plays as it is";
        else
            qInfo().noquote() << "TransparentVideo:" << name << "conversion stopped";
        return { result, {} };
    }
    if (!QFile::rename(part, copy)) {
        QFile::remove(part);
        // Another thread or process finished the same file first.
        if (QFileInfo::exists(copy)) return { Result::Copy, copy };
        qWarning().noquote() << "TransparentVideo:" << name
                             << "couldn't save its transparent copy, it plays without transparency";
        return { Result::Failed, {} };
    }
    qInfo().noquote() << "TransparentVideo:" << name
                      << "has an alpha stream, made a transparent copy in" << timer.elapsed()
                      << "ms," << QFileInfo(copy).size() / 1024 << "KB";
    pruneCache(copy);
    return { Result::Copy, copy };
}

}  // namespace crater::transparentvideo
