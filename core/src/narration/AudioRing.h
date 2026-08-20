#pragma once

#include <QList>
#include <QMutex>

namespace crater::narration {

// Fixed-capacity float ring buffer, overwrite-oldest.
//
// This is the *only* place captured audio is ever held (docs/narration.md §8:
// audio never touches disk, no recording, no cache). Fixed capacity is a
// security property, not a performance one — it makes "we cannot retain more
// than N seconds of the room" true by construction rather than by policy.
//
// Overwrite-oldest rather than block-on-full is deliberate. If the recognizer
// falls behind, the correct behaviour is to drop the stale audio and stay
// live with the preacher. Blocking the capture thread would stall the mic and
// desynchronize everything downstream.
//
// Threading: single producer (the audio device callback), single consumer
// (the recognizer thread), guarded by a plain mutex. The critical section is
// two memcpys at 16 kHz, so contention is not measurable and a lock-free ring
// would be complexity we can't justify.
class AudioRing
{
public:
    explicit AudioRing(int capacityFrames);

    // Append `n` frames, discarding the oldest on overflow. Writing more than
    // the capacity in one call keeps only the most recent `capacity` frames.
    void write(const float* src, int n);

    // Copy out up to `maxN` frames oldest-first. Returns how many were read.
    int read(float* dst, int maxN);

    // Read without consuming — used for the level meter.
    int available() const;
    int capacity()  const { return m_capacity; }

    // Drop everything. Called on disarm so no audio outlives the session.
    void clear();

    // Total frames dropped to overflow since construction. Surfaced so a
    // starved recognizer shows up as a diagnostic instead of silent gaps.
    qint64 overruns() const;

private:
    mutable QMutex m_mutex;
    QList<float>   m_buf;
    int            m_capacity = 0;
    int            m_head     = 0;   // next write index
    int            m_size     = 0;   // frames currently held
    qint64         m_overruns = 0;
};

}  // namespace crater::narration
