#include "narration/AudioTap.h"

#include <QAudioSource>
#include <QDateTime>
#include <QIODevice>
#include <QMediaDevices>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <utility>

namespace crater::narration {
namespace {

// Decode one sample to normalized float. QAudioFormat::normalizedSampleValue
// exists but goes through QVariant per sample, which is far too slow for a
// 48 kHz stereo stream.
inline float sampleToFloat(const char* p, QAudioFormat::SampleFormat fmt)
{
    switch (fmt) {
    case QAudioFormat::UInt8: {
        quint8 v;
        std::memcpy(&v, p, 1);
        return (float(v) - 128.0f) / 128.0f;
    }
    case QAudioFormat::Int16: {
        qint16 v;
        std::memcpy(&v, p, 2);
        return float(v) / 32768.0f;
    }
    case QAudioFormat::Int32: {
        qint32 v;
        std::memcpy(&v, p, 4);
        return float(double(v) / 2147483648.0);
    }
    case QAudioFormat::Float: {
        float v;
        std::memcpy(&v, p, 4);
        return v;
    }
    default:
        return 0.0f;
    }
}

}  // namespace

AudioTap::AudioTap(QObject* parent)
    : QObject(parent)
    , m_ring(kTargetRate * kRingSeconds)
{
}

AudioTap::~AudioTap()
{
    stop();
}

bool AudioTap::start(QString* error)
{
    const QAudioDevice dev = QMediaDevices::defaultAudioInput();
    if (dev.isNull()) {
        if (error) *error = QStringLiteral("No audio input device is available.");
        return false;
    }
    return start(dev, error);
}

bool AudioTap::start(const QAudioDevice& device, QString* error)
{
    stop();

    if (device.isNull()) {
        if (error) *error = QStringLiteral("The selected audio input device is not available.");
        return false;
    }

    // Ask for exactly what we want first. When the device can do 16 kHz mono
    // natively we skip conversion entirely and the driver's own resampler —
    // usually better than ours — does the work.
    QAudioFormat fmt;
    fmt.setSampleRate(kTargetRate);
    fmt.setChannelCount(1);
    fmt.setSampleFormat(QAudioFormat::Int16);

    if (!device.isFormatSupported(fmt)) {
        fmt = device.preferredFormat();
        if (!device.isFormatSupported(fmt)) {
            if (error) {
                *error = QStringLiteral("Audio device \"%1\" offers no usable capture format.")
                             .arg(device.description());
            }
            return false;
        }
    }

    if (fmt.sampleFormat() == QAudioFormat::Unknown || fmt.sampleRate() <= 0
        || fmt.channelCount() <= 0) {
        if (error) {
            *error = QStringLiteral("Audio device \"%1\" reported an invalid format.")
                         .arg(device.description());
        }
        return false;
    }

    m_sourceFormat = fmt;
    m_deviceName   = device.description();

    m_phase = 0;
    m_acc   = 0.0f;
    m_accN  = 0;
    m_ring.clear();

    m_source = std::make_unique<QAudioSource>(device, fmt);

    connect(m_source.get(), &QAudioSource::stateChanged, this, [this](QAudio::State state) {
        if (state != QAudio::StoppedState) return;
        if (!m_source || m_source->error() == QAudio::NoError) return;
        const QString reason = QStringLiteral("Audio capture stopped unexpectedly on \"%1\".")
                                   .arg(m_deviceName);
        stop();
        emit stopped(reason);
    });

    m_io = m_source->start();
    if (!m_io) {
        const QString reason = QStringLiteral("Could not open audio device \"%1\".").arg(m_deviceName);
        m_source.reset();
        if (error) *error = reason;
        return false;
    }

    connect(m_io, &QIODevice::readyRead, this, &AudioTap::onReadyRead);
    return true;
}

void AudioTap::stop()
{
    if (m_io) {
        disconnect(m_io, nullptr, this, nullptr);
        m_io = nullptr;
    }
    if (m_source) {
        m_source->stop();
        m_source.reset();
    }
    // Session-scoped: the room does not survive a disarm.
    m_ring.clear();
    m_levelDb = -100.0f;
}

bool AudioTap::isRunning() const
{
    return m_source != nullptr && m_io != nullptr;
}

void AudioTap::onReadyRead()
{
    if (!m_io) return;

    const QByteArray chunk = m_io->readAll();
    if (chunk.isEmpty()) return;

    appendConverted(chunk.constData(), chunk.size());
}

void AudioTap::appendConverted(const char* bytes, qint64 byteCount)
{
    const int channels   = m_sourceFormat.channelCount();
    const int bytesPer   = m_sourceFormat.bytesPerSample();
    const int frameBytes = bytesPer * channels;
    if (frameBytes <= 0) return;

    const qint64 frames = byteCount / frameBytes;
    if (frames <= 0) return;

    const int  inRate = m_sourceFormat.sampleRate();
    const auto sfmt   = m_sourceFormat.sampleFormat();

    m_scratch.clear();
    // Upper bound on emitted frames, so the append loop below never reallocs.
    m_scratch.reserve(int(frames * kTargetRate / std::max(1, inRate)) + 2);

    const char* p = bytes;
    for (qint64 f = 0; f < frames; ++f, p += frameBytes) {
        // Downmix. A lapel mic on a stereo interface is commonly wired to one
        // channel only, so averaging costs 6 dB on that setup — acceptable
        // next to picking a channel and getting silence on the other rig.
        float mono = 0.0f;
        for (int c = 0; c < channels; ++c)
            mono += sampleToFloat(p + c * bytesPer, sfmt);
        mono /= float(channels);

        m_acc += mono;
        ++m_accN;

        m_phase += kTargetRate;
        while (m_phase >= inRate) {
            m_phase -= inRate;
            m_scratch.append(m_accN > 0 ? m_acc / float(m_accN) : mono);
            m_acc  = 0.0f;
            m_accN = 0;
        }
    }

    if (m_scratch.isEmpty()) return;

    m_ring.write(m_scratch.constData(), int(m_scratch.size()));

    double sum = 0.0;
    for (float v : std::as_const(m_scratch))
        sum += double(v) * double(v);
    const double rms = std::sqrt(sum / double(m_scratch.size()));
    m_levelDb = rms <= 1e-9 ? -100.0f : float(std::max(-100.0, 20.0 * std::log10(rms)));

    emit audioReady();

    // Throttle the meter. Device buffers arrive every ~10 ms and a QML
    // binding does not need 100 updates a second.
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_lastLevelEmit >= 50) {
        m_lastLevelEmit = now;
        emit levelChanged();
    }
}

}  // namespace crater::narration
