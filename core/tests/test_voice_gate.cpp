// Tests for crater::narration audio plumbing — the ring buffer and the
// voice-activity gate (docs/narration.md §7.1, phase 1).
//
// Run via CTest: `ctest --test-dir <build-dir> -R voice_gate --output-on-failure`
//
// Coverage philosophy: both classes are deterministic over synthetic PCM, so
// no microphone is involved. The gate's job is deciding where an utterance
// starts and stops, and the two ways it can be wrong are both tested here —
// firing on a cough, and cutting a sentence in half at a rhetorical pause.
//
// AudioTap itself is not covered: it is device negotiation plus a decimation
// loop, and the parts worth testing (format conversion) can't be reached
// without a real QAudioSource. Phase 1's exit criterion for it is a live mic.

#include <QObject>
#include <QTest>

#include "narration/AudioRing.h"
#include "narration/VoiceGate.h"

#include <algorithm>
#include <cmath>

using crater::narration::AudioRing;
using crater::narration::VoiceGate;

namespace {

constexpr int    kRate = 16000;
// Spelled out rather than M_PI: that macro is not defined by MSVC's <cmath>
// without _USE_MATH_DEFINES, so using it here would break the Windows build.
constexpr double kPi = 3.14159265358979323846;

int msToFrames(int ms) { return (kRate * ms) / 1000; }

// A 220 Hz tone at the given amplitude. 0.3 lands around -13 dBFS RMS, well
// clear of the -38 dB open threshold.
QList<float> tone(int ms, float amplitude = 0.3f)
{
    const int    n = msToFrames(ms);
    QList<float> out;
    out.reserve(n);
    for (int i = 0; i < n; ++i)
        out.append(float(amplitude * std::sin(2.0 * kPi * 220.0 * double(i) / double(kRate))));
    return out;
}

QList<float> silence(int ms)
{
    return QList<float>(msToFrames(ms), 0.0f);
}

QList<VoiceGate::Event> feed(VoiceGate& g, const QList<float>& samples)
{
    return g.push(samples.constData(), int(samples.size()));
}

int countOf(const QList<VoiceGate::Event>& evs, VoiceGate::Event want)
{
    int n = 0;
    for (auto e : evs)
        if (e == want) ++n;
    return n;
}

}  // namespace

class TestVoiceGate : public QObject
{
    Q_OBJECT

private slots:

    // ── AudioRing ───────────────────────────────────────────────────────

    void ring_write_then_read_roundtrips()
    {
        AudioRing r(1024);
        const QList<float> in{ 0.1f, 0.2f, 0.3f, 0.4f };
        r.write(in.constData(), int(in.size()));
        QCOMPARE(r.available(), 4);

        QList<float> out(4, 0.0f);
        QCOMPARE(r.read(out.data(), 4), 4);
        QCOMPARE(out, in);
        QCOMPARE(r.available(), 0);
    }

    void ring_read_is_oldest_first_across_wrap()
    {
        AudioRing r(4);
        const QList<float> a{ 1.0f, 2.0f, 3.0f };
        r.write(a.constData(), 3);

        QList<float> drain(2, 0.0f);
        QCOMPARE(r.read(drain.data(), 2), 2);      // consume 1,2 — head is mid-buffer
        QCOMPARE(drain, (QList<float>{ 1.0f, 2.0f }));

        const QList<float> b{ 4.0f, 5.0f };        // wraps
        r.write(b.constData(), 2);

        QList<float> out(3, 0.0f);
        QCOMPARE(r.read(out.data(), 3), 3);
        QCOMPARE(out, (QList<float>{ 3.0f, 4.0f, 5.0f }));
    }

    // A recognizer falling behind must cost us stale audio, never a stalled
    // capture thread.
    void ring_overflow_drops_oldest_and_counts()
    {
        AudioRing r(4);
        const QList<float> in{ 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f };
        r.write(in.constData(), 6);

        QCOMPARE(r.available(), 4);
        QVERIFY(r.overruns() >= 2);

        QList<float> out(4, 0.0f);
        QCOMPARE(r.read(out.data(), 4), 4);
        QCOMPARE(out, (QList<float>{ 3.0f, 4.0f, 5.0f, 6.0f }));
    }

    void ring_clear_discards_everything()
    {
        AudioRing r(64);
        const QList<float> in(32, 0.5f);
        r.write(in.constData(), 32);
        r.clear();
        QCOMPARE(r.available(), 0);
    }

    void ring_read_from_empty_is_zero()
    {
        AudioRing    r(64);
        QList<float> out(8, 0.0f);
        QCOMPARE(r.read(out.data(), 8), 0);
    }

    // ── VoiceGate ───────────────────────────────────────────────────────

    void gate_silence_produces_no_events()
    {
        VoiceGate g;
        QVERIFY(feed(g, silence(3000)).isEmpty());
        QVERIFY(!g.inSpeech());
    }

    void gate_opens_on_sustained_speech()
    {
        VoiceGate g;
        const auto evs = feed(g, tone(1000));
        QCOMPARE(countOf(evs, VoiceGate::Event::SpeechStarted), 1);
        QCOMPARE(countOf(evs, VoiceGate::Event::SpeechEnded), 0);
        QVERIFY(g.inSpeech());
    }

    void gate_closes_after_hangover()
    {
        VoiceGate g;
        feed(g, tone(1000));
        QVERIFY(g.inSpeech());

        const auto evs = feed(g, silence(1200));   // well past the 600 ms hangover
        QCOMPARE(countOf(evs, VoiceGate::Event::SpeechEnded), 1);
        QVERIFY(!g.inSpeech());
    }

    // The cough test. A mic bump clears the energy threshold easily; what it
    // cannot do is sustain for minSpeechMs.
    void gate_rejects_blips_shorter_than_min_speech()
    {
        VoiceGate g;
        const auto evs = feed(g, tone(80));        // under the 200 ms floor
        QVERIFY(evs.isEmpty());
        QVERIFY(!g.inSpeech());
    }

    // The rhetorical-pause test. Cutting here would hand the detectors
    // sentence fragments, and "turn with me to" / "first Corinthians thirteen"
    // as two utterances loses the reference entirely.
    void gate_holds_through_a_pause_shorter_than_hangover()
    {
        VoiceGate  g;
        QList<VoiceGate::Event> all;
        all += feed(g, tone(600));
        all += feed(g, silence(300));   // under the 600 ms hangover
        all += feed(g, tone(600));

        QCOMPARE(countOf(all, VoiceGate::Event::SpeechStarted), 1);
        QCOMPARE(countOf(all, VoiceGate::Event::SpeechEnded), 0);
        QVERIFY(g.inSpeech());
    }

    void gate_segments_two_separate_utterances()
    {
        VoiceGate  g;
        QList<VoiceGate::Event> all;
        all += feed(g, tone(700));
        all += feed(g, silence(1000));
        all += feed(g, tone(700));
        all += feed(g, silence(1000));

        QCOMPARE(countOf(all, VoiceGate::Event::SpeechStarted), 2);
        QCOMPARE(countOf(all, VoiceGate::Event::SpeechEnded), 2);
    }

    // Continuous speech has to be cut somewhere or whisper's cost runs away.
    void gate_force_closes_at_max_utterance()
    {
        VoiceGate::Config cfg;
        cfg.maxUtteranceMs = 1000;
        VoiceGate g(cfg);

        const auto evs = feed(g, tone(3000));
        QVERIFY(countOf(evs, VoiceGate::Event::SpeechEnded) >= 1);
    }

    // Samples arrive in whatever buffer size the device chose, which will not
    // divide evenly into 20 ms analysis frames.
    void gate_handles_unaligned_buffers()
    {
        VoiceGate    g;
        const QList<float> t = tone(1000);

        QList<VoiceGate::Event> all;
        int i = 0;
        while (i < t.size()) {
            const int chunk = std::min<int>(37, int(t.size()) - i);   // deliberately awkward
            all += g.push(t.constData() + i, chunk);
            i += chunk;
        }
        QCOMPARE(countOf(all, VoiceGate::Event::SpeechStarted), 1);
    }

    void gate_flush_closes_an_open_utterance()
    {
        VoiceGate g;
        feed(g, tone(1000));
        QVERIFY(g.inSpeech());
        QVERIFY(g.flush());
        QVERIFY(!g.inSpeech());
        QVERIFY(!g.flush());   // nothing left to close
    }

    void gate_quiet_speech_below_threshold_does_not_open()
    {
        VoiceGate g;
        const auto evs = feed(g, tone(1000, 0.002f));   // roughly -57 dBFS
        QVERIFY(evs.isEmpty());
    }

    void gate_elapsed_tracks_consumed_audio()
    {
        VoiceGate g;
        feed(g, silence(1000));
        // Frame-quantized, so allow one 20 ms frame of slack.
        QVERIFY(qAbs(g.elapsedMs() - 1000) <= g.config().frameMs);
    }

    void gate_reset_clears_state_and_clock()
    {
        VoiceGate g;
        feed(g, tone(1000));
        g.reset();
        QVERIFY(!g.inSpeech());
        QCOMPARE(g.elapsedMs(), qint64(0));
    }
};

QTEST_GUILESS_MAIN(TestVoiceGate)
#include "test_voice_gate.moc"
