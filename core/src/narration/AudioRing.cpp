#include "narration/AudioRing.h"

#include <QMutexLocker>

#include <algorithm>
#include <cstring>

namespace crater::narration {

AudioRing::AudioRing(int capacityFrames)
    : m_capacity(std::max(1, capacityFrames))
{
    m_buf.resize(m_capacity);
}

void AudioRing::write(const float* src, int n)
{
    if (!src || n <= 0) return;

    QMutexLocker lock(&m_mutex);

    // A single write larger than the ring can only leave the last `capacity`
    // frames, so skip straight to them rather than looping over data we're
    // about to overwrite.
    if (n >= m_capacity) {
        m_overruns += n - m_capacity;
        std::memcpy(m_buf.data(), src + (n - m_capacity), size_t(m_capacity) * sizeof(float));
        m_head = 0;
        m_size = m_capacity;
        return;
    }

    const int first = std::min(n, m_capacity - m_head);
    std::memcpy(m_buf.data() + m_head, src, size_t(first) * sizeof(float));
    if (n > first)
        std::memcpy(m_buf.data(), src + first, size_t(n - first) * sizeof(float));

    m_head = (m_head + n) % m_capacity;

    const int room = m_capacity - m_size;
    if (n > room) m_overruns += n - room;
    m_size = std::min(m_capacity, m_size + n);
}

int AudioRing::read(float* dst, int maxN)
{
    if (!dst || maxN <= 0) return 0;

    QMutexLocker lock(&m_mutex);

    const int n = std::min(maxN, m_size);
    if (n == 0) return 0;

    // Oldest frame sits `m_size` behind the write head.
    const int tail  = ((m_head - m_size) % m_capacity + m_capacity) % m_capacity;
    const int first = std::min(n, m_capacity - tail);

    std::memcpy(dst, m_buf.constData() + tail, size_t(first) * sizeof(float));
    if (n > first)
        std::memcpy(dst + first, m_buf.constData(), size_t(n - first) * sizeof(float));

    m_size -= n;
    return n;
}

int AudioRing::available() const
{
    QMutexLocker lock(&m_mutex);
    return m_size;
}

void AudioRing::clear()
{
    QMutexLocker lock(&m_mutex);
    m_head = 0;
    m_size = 0;
    // Zero the storage as well. The ring outlives a disarm, and leaving the
    // room's audio sitting in a heap allocation would defeat the point of
    // "transcripts and audio are session-scoped" (docs/narration.md §8).
    std::fill(m_buf.begin(), m_buf.end(), 0.0f);
}

qint64 AudioRing::overruns() const
{
    QMutexLocker lock(&m_mutex);
    return m_overruns;
}

}  // namespace crater::narration
