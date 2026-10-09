#pragma once

#include <QList>

namespace crater::narration {

// Voice activity detection and utterance segmentation over 16 kHz mono float.
//
// Whisper is not a streaming model, so something has to decide where one
// utterance ends and the next begins. Fixed windows would cut mid-word and
// burn inference on silence; speech-pause boundaries are both cheaper and a
// better fit for the detectors downstream, which want whole clauses.
//
// This is an energy gate with hysteresis and a hangover timer — no model, no
// dependency, and deterministic enough to unit-test against synthetic PCM.
// docs/narration.md §7.1 specifies Silero VAD, which is strictly better in a
// noisy room (it distinguishes speech from a slammed door; energy cannot).
// Silero is a drop-in behind this same interface and is the intended upgrade;
// this gets the pipeline end-to-end without adding ONNX Runtime on day one.
class VoiceGate
{
public:
    struct Config
    {
        // Hysteresis. Opening higher than it closes stops a voice hovering
        // near the threshold from machine-gunning start/stop events.
        float speechDb  = -38.0f;   // rise above this to open
        float silenceDb = -48.0f;   // fall below this to start closing

        // Ignore blips. A cough, a mic bump, or a chair scrape clears the
        // energy threshold easily but not for 200 ms.
        int minSpeechMs = 200;

        // Silence tolerated inside one utterance. Preachers pause for effect,
        // and cutting at the first gap would shred a sentence into fragments
        // that neither the citation grammar nor the quote matcher can use.
        int hangoverMs = 600;

        // Backstop for continuous speech. Whisper's cost grows with input
        // length and a preacher can talk for minutes without a real pause, so
        // force a cut and let RefContext carry meaning across the seam.
        int maxUtteranceMs = 15000;

        // Analysis frame. 20 ms is 320 frames at 16 kHz.
        int frameMs = 20;
    };

    enum class Event
    {
        SpeechStarted,
        SpeechEnded,
    };

    explicit VoiceGate(Config cfg = {});

    // Feed 16 kHz mono samples. Returns any boundary events crossed, in
    // order. Input need not align to frame boundaries; the remainder is
    // carried into the next call.
    QList<Event> push(const float* samples, int count);

    // Close an open utterance immediately, e.g. on disarm. Returns true if
    // there was one to close.
    bool flush();

    bool  inSpeech() const { return m_state == State::Speech; }
    float levelDb()  const { return m_lastDb; }

    // Milliseconds of audio consumed since construction or reset(). This is
    // the session clock every downstream timestamp is expressed in.
    qint64 elapsedMs() const;

    void reset();

    const Config& config() const { return m_cfg; }

private:
    enum class State
    {
        Idle,
        Opening,   // above threshold, not yet past minSpeechMs
        Speech,
    };

    static constexpr int kSampleRate = 16000;

    // dBFS of one analysis frame. Digital silence is clamped rather than
    // returning -inf so callers can compare without special-casing.
    static float frameDb(const float* frame, int n);

    Config m_cfg;
    State  m_state = State::Idle;

    // One analysis frame, allocated once at construction and refilled in
    // place. Device buffers don't align to frame boundaries, so a partial
    // frame carries across push() calls; m_fill is how much of it is valid.
    QList<float> m_frameBuf;
    int          m_fill         = 0;
    int          m_frameSamples = 0;
    float        m_lastDb       = -100.0f;
    int          m_openMs       = 0;   // time above threshold while Opening
    int          m_quietMs      = 0;   // time below threshold while in Speech
    int          m_utteranceMs  = 0;
    qint64       m_totalFrames  = 0;
};

}  // namespace crater::narration
