#include "narration/VoiceGate.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace crater::narration {

VoiceGate::VoiceGate(Config cfg)
    : m_cfg(cfg)
{
    m_frameSamples = std::max(1, (kSampleRate * m_cfg.frameMs) / 1000);
    m_frameBuf.resize(m_frameSamples);
}

float VoiceGate::frameDb(const float* frame, int n)
{
    if (n <= 0) return -100.0f;

    double sum = 0.0;
    for (int i = 0; i < n; ++i)
        sum += double(frame[i]) * double(frame[i]);

    const double rms = std::sqrt(sum / double(n));
    if (rms <= 1e-9) return -100.0f;

    return float(std::max(-100.0, 20.0 * std::log10(rms)));
}

QList<VoiceGate::Event> VoiceGate::push(const float* samples, int count)
{
    QList<Event> events;
    if (!samples || count <= 0) return events;

    int consumed = 0;
    while (consumed < count) {
        // Top the carry-over buffer up to one full analysis frame.
        const int want = m_frameSamples - m_fill;
        const int take = std::min(want, count - consumed);
        std::memcpy(m_frameBuf.data() + m_fill, samples + consumed, size_t(take) * sizeof(float));
        m_fill   += take;
        consumed += take;

        if (m_fill < m_frameSamples) break;   // wait for more

        m_lastDb = frameDb(m_frameBuf.constData(), m_frameSamples);
        m_fill   = 0;
        ++m_totalFrames;

        const int  frameMs = m_cfg.frameMs;
        const bool loud    = m_lastDb >= m_cfg.speechDb;
        const bool quiet   = m_lastDb < m_cfg.silenceDb;

        switch (m_state) {
        case State::Idle:
            if (loud) {
                m_state  = State::Opening;
                m_openMs = frameMs;
            }
            break;

        case State::Opening:
            if (!loud) {
                // Didn't sustain. Blip rejected.
                m_state  = State::Idle;
                m_openMs = 0;
                break;
            }
            m_openMs += frameMs;
            if (m_openMs >= m_cfg.minSpeechMs) {
                m_state       = State::Speech;
                m_quietMs     = 0;
                // Count the qualifying run as part of the utterance so
                // maxUtteranceMs measures speech, not time since the gate
                // happened to latch.
                m_utteranceMs = m_openMs;
                m_openMs      = 0;
                events.append(Event::SpeechStarted);
            }
            break;

        case State::Speech:
            m_utteranceMs += frameMs;

            // Hangover: only silence *below the close threshold* accumulates,
            // and any frame above it resets the count. That's what lets a
            // rhetorical pause sit inside one utterance.
            m_quietMs = quiet ? m_quietMs + frameMs : 0;

            if (m_quietMs >= m_cfg.hangoverMs || m_utteranceMs >= m_cfg.maxUtteranceMs) {
                m_state       = State::Idle;
                m_quietMs     = 0;
                m_utteranceMs = 0;
                events.append(Event::SpeechEnded);
            }
            break;
        }
    }

    return events;
}

bool VoiceGate::flush()
{
    const bool wasOpen = (m_state == State::Speech);
    m_state       = State::Idle;
    m_openMs      = 0;
    m_quietMs     = 0;
    m_utteranceMs = 0;
    m_fill        = 0;
    return wasOpen;
}

qint64 VoiceGate::elapsedMs() const
{
    return m_totalFrames * qint64(m_cfg.frameMs);
}

void VoiceGate::reset()
{
    flush();
    m_lastDb      = -100.0f;
    m_totalFrames = 0;
}

}  // namespace crater::narration
