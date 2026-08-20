// Measures the narration audio chain and scores speech recognition against
// known text. docs/narration.md §7.1.
//
// This exists because "it isn't picking up my words" is not actionable. It can
// mean the microphone is wrong, the capture chain is mangling the audio, the
// level is too low for the model, the model is too small, or the model is fine
// and the words really were said differently. Those have five different fixes
// and no amount of listening to the app can tell them apart.
//
//   narration_bench --list
//   narration_bench --record out.wav [--device <id>] [--seconds 20]
//   narration_bench --analyze out.wav
//   narration_bench --transcribe out.wav --model <ggml.bin> [--repeat 3]
//   narration_bench --score out.wav --model <ggml.bin> --truth truth.txt
//
// A developer tool, not part of the application, and the reason it can write
// audio to disk at all: §8's "audio never touches disk" is a property of
// crater.exe, whose microphone opens on an operator's click in a room full of
// people who did not consent to being recorded. This is a separate binary that
// records only what someone explicitly asks it to, to a path they name.
//
// It captures through AudioTap — the same class the app uses — so the downmix,
// the resampler and the format negotiation under test are the ones that ship,
// not a reimplementation that might be correct where the real one is not.

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QMediaDevices>
#include <QAudioDevice>
#include <QStringDecoder>
#include <QTextStream>
#include <QTimer>

#include "narration/AudioTap.h"
#include "narration/SpokenNumbers.h"
#include "narration/VoiceGate.h"
#include "narration/WhisperRecognizer.h"

#include <cmath>

using namespace crater;
using narration::AudioTap;
using narration::VoiceGate;
using narration::WhisperRecognizer;

namespace {

QTextStream& out()
{
    static QTextStream s(stdout);
    return s;
}

constexpr int kRate = AudioTap::kTargetRate;   // 16 kHz, what whisper wants

// ── WAV ──────────────────────────────────────────────────────────────────
//
// 16-bit mono at the rate the pipeline actually runs at, so the file on disk
// is byte-for-byte what the recognizer was handed rather than a re-rendering
// of it.

void writeU32(QFile& f, quint32 v) { f.write(reinterpret_cast<const char*>(&v), 4); }
void writeU16(QFile& f, quint16 v) { f.write(reinterpret_cast<const char*>(&v), 2); }

bool writeWav(const QString& path, const QList<float>& samples, QString* error)
{
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        if (error) *error = QStringLiteral("cannot write %1").arg(path);
        return false;
    }

    const quint32 dataBytes = quint32(samples.size()) * 2;
    f.write("RIFF", 4);
    writeU32(f, 36 + dataBytes);
    f.write("WAVE", 4);
    f.write("fmt ", 4);
    writeU32(f, 16);
    writeU16(f, 1);                      // PCM
    writeU16(f, 1);                      // mono
    writeU32(f, kRate);
    writeU32(f, kRate * 2);              // byte rate
    writeU16(f, 2);                      // block align
    writeU16(f, 16);                     // bits
    f.write("data", 4);
    writeU32(f, dataBytes);

    for (const float v : samples) {
        const float  c = std::clamp(v, -1.0f, 1.0f);
        const qint16 s = qint16(std::lround(c * 32767.0f));
        f.write(reinterpret_cast<const char*>(&s), 2);
    }
    f.close();
    return true;
}

bool readWav(const QString& path, QList<float>* samples, QString* error)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        if (error) *error = QStringLiteral("cannot read %1").arg(path);
        return false;
    }
    const QByteArray all = f.readAll();
    f.close();

    if (all.size() < 44 || !all.startsWith("RIFF") || all.mid(8, 4) != "WAVE") {
        if (error) *error = QStringLiteral("%1 is not a WAV file").arg(path);
        return false;
    }

    // Walk the chunk list rather than assuming a 44-byte header — plenty of
    // recorders insert LIST/fact chunks and a fixed offset would read those
    // bytes as audio.
    int      pos      = 12;
    int      channels = 1;
    int      rate     = kRate;
    int      bits     = 16;
    bool     haveFmt  = false;
    while (pos + 8 <= all.size()) {
        const QByteArray id = all.mid(pos, 4);
        quint32 size = 0;
        std::memcpy(&size, all.constData() + pos + 4, 4);
        const int body = pos + 8;

        if (id == "fmt " && body + 16 <= all.size()) {
            quint16 c = 0, b = 0;
            quint32 r = 0;
            std::memcpy(&c, all.constData() + body + 2,  2);
            std::memcpy(&r, all.constData() + body + 4,  4);
            std::memcpy(&b, all.constData() + body + 14, 2);
            channels = std::max<int>(1, c);
            rate     = int(r);
            bits     = int(b);
            haveFmt  = true;
        } else if (id == "data") {
            if (!haveFmt) {
                if (error) *error = QStringLiteral("%1 has no format chunk").arg(path);
                return false;
            }
            if (bits != 16) {
                if (error) *error = QStringLiteral("only 16-bit WAV is supported (%1 is %2-bit)")
                                        .arg(path).arg(bits);
                return false;
            }
            const int frames = int(std::min<qint64>(size, all.size() - body)) / (2 * channels);
            samples->clear();
            samples->reserve(frames);
            for (int i = 0; i < frames; ++i) {
                float mono = 0.0f;
                for (int c = 0; c < channels; ++c) {
                    qint16 s = 0;
                    std::memcpy(&s, all.constData() + body + (i * channels + c) * 2, 2);
                    mono += float(s) / 32768.0f;
                }
                samples->append(mono / float(channels));
            }
            if (rate != kRate) {
                out() << "  warning: file is " << rate << " Hz, the pipeline runs at "
                      << kRate << " Hz. Transcription of this file is not representative.\n";
            }
            return true;
        }

        pos = body + int(size) + (size & 1);   // chunks are word-aligned
    }

    if (error) *error = QStringLiteral("%1 has no data chunk").arg(path);
    return false;
}

// ── Level report ─────────────────────────────────────────────────────────
//
// The first fork in every diagnosis. Whisper is trained on roughly normalized
// speech; a peak around -30 dBFS is a sixth of full scale, and the model
// answers quiet input with confident invention rather than with silence.
void report(const QList<float>& s)
{
    if (s.isEmpty()) { out() << "  (no samples)\n"; return; }

    double sum = 0.0;
    float  peak = 0.0f;
    int    clipped = 0;
    for (const float v : s) {
        const float a = std::fabs(v);
        peak = std::max(peak, a);
        if (a >= 0.999f) ++clipped;
        sum += double(v) * double(v);
    }
    const double rms   = std::sqrt(sum / double(s.size()));
    const auto   db    = [](double x) { return x <= 1e-9 ? -100.0 : 20.0 * std::log10(x); };
    const double secs  = double(s.size()) / double(kRate);

    out() << QStringLiteral("  duration   %1 s\n").arg(secs, 0, 'f', 1);
    out() << QStringLiteral("  peak       %1 dBFS\n").arg(db(peak), 0, 'f', 1);
    out() << QStringLiteral("  rms        %1 dBFS\n").arg(db(rms), 0, 'f', 1);
    if (clipped > 0)
        out() << QStringLiteral("  clipped    %1 samples\n").arg(clipped);

    // How much of the recording the gate would even consider speech. A number
    // near zero here with audible words means the thresholds are wrong for
    // this microphone, not that recognition failed.
    VoiceGate gate;
    int speechFrames = 0, frames = 0;
    const int frameLen = kRate / 50;   // 20 ms
    for (int i = 0; i + frameLen <= s.size(); i += frameLen) {
        gate.push(s.constData() + i, frameLen);
        ++frames;
        if (gate.inSpeech()) ++speechFrames;
    }
    const double pct = frames > 0 ? 100.0 * double(speechFrames) / double(frames) : 0.0;
    out() << QStringLiteral("  voiced     %1% of frames\n").arg(pct, 0, 'f', 0);

    out() << "\n";
    if (db(peak) < -25.0)
        out() << "  -> QUIET. Raise the input gain in Windows sound settings; this is the\n"
                 "     single most common cause of invented words.\n";
    if (clipped > s.size() / 500)
        out() << "  -> CLIPPING. Lower the input gain.\n";
    if (pct < 10.0)
        out() << "  -> Almost nothing registered as speech. Wrong device, or a gate\n"
                 "     threshold that does not suit this microphone.\n";
    if (db(peak) >= -25.0 && pct >= 10.0 && clipped <= s.size() / 500)
        out() << "  -> Levels look healthy. If recognition is still wrong, the audio is\n"
                 "     not the problem: compare engines with --score.\n";
    out().flush();
}

// ── Word error rate ──────────────────────────────────────────────────────
//
// The only honest way to compare engines. "It sounds better" is not a
// measurement, and the differences between candidates here are small enough
// that an opinion formed over three sentences will be wrong.

// Decode a reference file whose encoding nobody chose deliberately.
//
// `echo ... > truth.txt` in Windows PowerShell 5 writes UTF-16LE. Read as
// UTF-8 that is every letter separated by a NUL, so "turn with me to john"
// normalizes to twenty single-letter words and the WER comes back as a
// perfect 100% against a transcript that was very nearly right. A measurement
// tool that reports a catastrophic score for a file-encoding mismatch is
// worse than no measurement, because the number looks like an answer.
// Read the BOM directly rather than asking QStringConverter to guess. The
// guess was tried first and produced a string with alternating endianness —
// "turn 眀椀琀栀 me 琀漀 john" from a file that is unambiguous UTF-16LE from
// its first two bytes onward. Whatever explains that, a scoring tool has no
// business being subtle about encodings: the input is four well-known byte
// prefixes and everything else is UTF-8.
QString decodeText(const QByteArray& raw)
{
    const auto byteAt = [&raw](int i) { return quint8(raw.at(i)); };

    if (raw.size() >= 2 && byteAt(0) == 0xFF && byteAt(1) == 0xFE) {
        const int units = (raw.size() - 2) / 2;
        QString s(units, Qt::Uninitialized);
        for (int i = 0; i < units; ++i)
            s[i] = QChar(char16_t(byteAt(2 + i * 2) | (byteAt(3 + i * 2) << 8)));
        return s;
    }
    if (raw.size() >= 2 && byteAt(0) == 0xFE && byteAt(1) == 0xFF) {
        const int units = (raw.size() - 2) / 2;
        QString s(units, Qt::Uninitialized);
        for (int i = 0; i < units; ++i)
            s[i] = QChar(char16_t((byteAt(2 + i * 2) << 8) | byteAt(3 + i * 2)));
        return s;
    }
    if (raw.startsWith("\xEF\xBB\xBF"))
        return QString::fromUtf8(raw.mid(3));
    return QString::fromUtf8(raw);
}

// Reduce both sides to the tokens the DETECTOR will compare, not the tokens a
// transcription contest would.
//
// Numbers are why. Whisper writes "chapter 3 verse 16" where the reference
// says "chapter three verse sixteen", and scored literally that is two errors
// out of nine words — enough to turn an 11% WER into 33% and push the verdict
// from "good" to "too high, fix your audio". It is not an error at all:
// CitationDetector runs both forms through the same parser and gets John 3:16
// either way.
//
// So collapse spoken numbers to digits with narration::parseNumberPhrase, the
// exact function the detector uses. The measurement then answers the question
// that matters — will the right verse be found — instead of a question about
// formatting that nobody is asking.
QStringList normalize(const QString& text)
{
    QString t;
    t.reserve(text.size());
    for (const QChar c : text) {
        if (c.isLetterOrNumber())    t.append(c.toLower());
        else if (c.isSpace())        t.append(QLatin1Char(' '));
        else if (c == QLatin1Char('\'')) continue;   // don't -> dont, both sides
        else                         t.append(QLatin1Char(' '));
    }

    const QStringList words = t.split(QLatin1Char(' '), Qt::SkipEmptyParts);

    QStringList out;
    out.reserve(words.size());
    for (int i = 0; i < words.size(); ) {
        if (const auto n = narration::parseNumberPhrase(words, i)) {
            out.append(QString::number(n->value));
            i = std::max(n->endIdx, i + 1);   // never stall on a zero-width parse
            continue;
        }
        out.append(words.at(i));
        ++i;
    }
    return out;
}

struct Wer { int substitutions = 0, deletions = 0, insertions = 0, refWords = 0; };

// Levenshtein over words. Reference against hypothesis, so deletions are words
// that were said and missed.
Wer wordErrorRate(const QStringList& ref, const QStringList& hyp)
{
    const int n = int(ref.size());
    const int m = int(hyp.size());

    QList<QList<int>> d(n + 1, QList<int>(m + 1, 0));
    for (int i = 0; i <= n; ++i) d[i][0] = i;
    for (int j = 0; j <= m; ++j) d[0][j] = j;

    for (int i = 1; i <= n; ++i) {
        for (int j = 1; j <= m; ++j) {
            const int cost = (ref[i - 1] == hyp[j - 1]) ? 0 : 1;
            d[i][j] = std::min({ d[i - 1][j] + 1,          // deletion
                                 d[i][j - 1] + 1,          // insertion
                                 d[i - 1][j - 1] + cost }); // substitution
        }
    }

    // Walk back to attribute the errors, which is what makes the number
    // actionable: all-deletions means the engine is dropping speech, all-
    // substitutions means it is mishearing it, and those are different faults.
    Wer w;
    w.refWords = n;
    int i = n, j = m;
    while (i > 0 || j > 0) {
        if (i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)) {
            if (ref[i - 1] != hyp[j - 1]) ++w.substitutions;
            --i; --j;
        } else if (i > 0 && d[i][j] == d[i - 1][j] + 1) {
            ++w.deletions; --i;
        } else {
            ++w.insertions; --j;
        }
    }
    return w;
}

// ── Commands ─────────────────────────────────────────────────────────────

int listDevices()
{
    const QAudioDevice def = QMediaDevices::defaultAudioInput();
    const auto devices = QMediaDevices::audioInputs();
    out() << devices.size() << " input device(s):\n\n";
    for (const QAudioDevice& d : devices) {
        out() << QStringLiteral("  %1%2\n     id: %3\n")
                     .arg(d.description())
                     .arg(d.id() == def.id() ? QStringLiteral("   [system default]") : QString())
                     .arg(QString::fromUtf8(d.id()));
    }
    out() << "\nRecord from one with:  narration_bench --record take.wav --device <id>\n";
    out().flush();
    return 0;
}

int record(const QString& path, const QString& deviceId, int seconds)
{
    QAudioDevice device = QMediaDevices::defaultAudioInput();
    if (!deviceId.isEmpty()) {
        bool found = false;
        for (const QAudioDevice& d : QMediaDevices::audioInputs()) {
            if (QString::fromUtf8(d.id()) == deviceId) { device = d; found = true; break; }
        }
        if (!found) {
            out() << "error: no input device with id " << deviceId << "\n";
            out() << "run --list to see what is connected\n";
            out().flush();
            return 1;
        }
    }
    if (device.isNull()) {
        out() << "error: no audio input device available\n";
        out().flush();
        return 1;
    }

    AudioTap tap;
    QString  error;
    if (!tap.start(device, &error)) {
        out() << "error: " << error << "\n";
        out().flush();
        return 1;
    }

    out() << "recording from \"" << device.description() << "\" for " << seconds << " s\n";
    out() << "speak now - say something you can write down word for word\n\n";
    out().flush();

    QList<float> captured;
    QObject::connect(&tap, &AudioTap::audioReady, &tap, [&tap, &captured]() {
        float buf[4096];
        int   n = 0;
        while ((n = tap.read(buf, 4096)) > 0)
            for (int i = 0; i < n; ++i) captured.append(buf[i]);
    });

    // A countdown, because recording silently for twenty seconds gives the
    // person talking no idea whether it is working.
    QTimer ticker;
    int remaining = seconds;
    QObject::connect(&ticker, &QTimer::timeout, [&]() {
        --remaining;
        out() << QStringLiteral("\r  %1 s left, level %2 dBFS      ")
                     .arg(remaining, 3).arg(double(tap.levelDb()), 6, 'f', 1);
        out().flush();
    });
    ticker.start(1000);

    QEventLoop loop;
    QTimer::singleShot(seconds * 1000, &loop, &QEventLoop::quit);
    loop.exec();

    tap.stop();
    out() << "\n\n";

    if (!writeWav(path, captured, &error)) {
        out() << "error: " << error << "\n";
        out().flush();
        return 1;
    }
    out() << "wrote " << path << "\n\n";
    report(captured);
    return 0;
}

int analyze(const QString& path)
{
    QList<float> samples;
    QString      error;
    out() << path << "\n";
    if (!readWav(path, &samples, &error)) {
        out() << "error: " << error << "\n";
        out().flush();
        return 1;
    }
    report(samples);
    return 0;
}

// `interim` runs the in-progress path instead of the finished-utterance one:
// the draft model if one was given, a capped encoder context, no temperature
// fallback. That pass is what an operator actually watches during a sermon,
// so being able to measure it separately is the difference between tuning the
// latency they feel and tuning the one they only meet after they stop talking.
int transcribe(const QString& wav, const QString& model, int repeat, const QString& truthFile,
               const QString& draftModel, bool interim, int windowSecs)
{
    QList<float> samples;
    QString      error;
    if (!readWav(wav, &samples, &error)) {
        out() << "error: " << error << "\n";
        out().flush();
        return 1;
    }

    // The tail, matching NarrationService::maybeDispatchInterim, which reads
    // the last kInterimWindowMs of the utterance rather than all of it.
    // Without this a bench run over a whole recording measures a case the app
    // never actually asks for, and reports the interim pass as several times
    // slower than it is in service.
    if (windowSecs > 0) {
        const qsizetype want = qsizetype(windowSecs) * kRate;
        if (samples.size() > want) samples = samples.mid(samples.size() - want);
    }

    WhisperRecognizer rec;
    if (!rec.load(model, &error)) {
        out() << "error: " << error << "\n";
        out().flush();
        return 1;
    }
    if (!draftModel.isEmpty() && !rec.loadDraft(draftModel, &error)) {
        out() << "error: " << error << "\n";
        out().flush();
        return 1;
    }

    // Level of what is actually being fed to the model. Printed because the
    // most expensive thing whisper does is hallucinate over a quiet room, and
    // a transcribe run that takes twenty seconds to return an empty string is
    // indistinguishable from a slow model unless you can see the level.
    double sumSq = 0.0;
    float  peak  = 0.0f;
    for (const float v : samples) { sumSq += double(v) * double(v); peak = std::max(peak, std::fabs(v)); }
    const double rms   = samples.isEmpty() ? 0.0 : std::sqrt(sumSq / double(samples.size()));
    const auto   toDb  = [](double v) { return v <= 1e-9 ? -100.0 : 20.0 * std::log10(v); };

    const double audioSecs = double(samples.size()) / double(kRate);
    out() << "model:  " << QFileInfo(model).fileName() << "  (" << rec.threadCount()
          << " threads)\n";
    out() << QStringLiteral("level:  peak %1 dBFS, rms %2 dBFS\n")
                 .arg(toDb(double(peak)), 0, 'f', 1).arg(toDb(rms), 0, 'f', 1);
    if (!draftModel.isEmpty())
        out() << "draft:  " << QFileInfo(draftModel).fileName() << "\n";
    out() << "pass:   " << (interim ? "interim (live hypothesis)" : "final (finished utterance)")
          << "\n";
    out() << "audio:  " << QString::number(audioSecs, 'f', 1) << " s\n\n";
    out().flush();

    QString  text;
    QList<double> times;
    for (int i = 0; i < std::max(1, repeat); ++i) {
        QString got;
        QEventLoop loop;
        // The interim path answers on partial(), and answers even when it has
        // nothing — that empty reply is what releases the caller's in-flight
        // slot in NarrationService, so waiting on transcribed() here would
        // hang forever.
        if (interim)
            QObject::connect(&rec, &WhisperRecognizer::partial, &rec,
                             [&](const QString& t, qint64) { got = t; loop.quit(); });
        else
            QObject::connect(&rec, &WhisperRecognizer::transcribed, &rec,
                             [&](const QString& t, qint64) { got = t; loop.quit(); });
        QObject::connect(&rec, &WhisperRecognizer::failed, &rec,
                         [&](const QString& m) { got = QStringLiteral("<failed: %1>").arg(m);
                                                 loop.quit(); });
        QElapsedTimer clock;
        clock.start();
        // Queued so the event loop above is running when the signal fires.
        QMetaObject::invokeMethod(&rec,
                                  [&]() {
                                      if (interim) rec.transcribeInterim(samples, 0);
                                      else         rec.transcribe(samples, 0);
                                  },
                                  Qt::QueuedConnection);
        loop.exec();
        times.append(double(clock.elapsed()) / 1000.0);
        text = got;
        QObject::disconnect(&rec, nullptr, &rec, nullptr);
    }

    double best = times.first(), total = 0.0;
    for (const double t : times) { best = std::min(best, t); total += t; }
    const double mean = total / double(times.size());

    out() << "heard:  \"" << text << "\"\n\n";
    out() << QStringLiteral("wall clock  %1 s mean, %2 s best\n").arg(mean, 0, 'f', 2)
                                                                 .arg(best, 0, 'f', 2);
    // The number that decides whether an engine can keep up at all: below 1.0
    // it transcribes faster than people talk.
    out() << QStringLiteral("realtime    %1x  (< 1.0 keeps up with speech)\n")
                 .arg(mean / audioSecs, 0, 'f', 2);

    if (!truthFile.isEmpty()) {
        QFile tf(truthFile);
        // NOT QIODevice::Text, and this is the whole bug that made a nearly
        // correct transcript score 78% wrong.
        //
        // Text mode strips CR bytes. In UTF-16LE a newline is `0d 00 0a 00`,
        // so stripping the lone 0d removes ONE byte per line and shifts every
        // following byte pair by one. The result decodes with alternating
        // endianness — "turn 眀椀琀栀 me 琀漀 john" — correct on odd lines,
        // byte-swapped on even ones, which reads like an encoding-detection
        // failure and is nothing of the sort. Decoding is decodeText's job;
        // this call's only job is to hand over the bytes unaltered.
        if (!tf.open(QIODevice::ReadOnly)) {
            out() << "\nerror: cannot read " << truthFile << "\n";
            out().flush();
            return 1;
        }
        const QString truth = decodeText(tf.readAll());
        tf.close();

        const QStringList ref = normalize(truth);
        const QStringList hyp = normalize(text);
        const Wer w = wordErrorRate(ref, hyp);
        const int errors = w.substitutions + w.deletions + w.insertions;
        const double wer = w.refWords > 0 ? 100.0 * double(errors) / double(w.refWords) : 0.0;

        out() << "\n";
        out() << QStringLiteral("WER         %1%  (%2 errors over %3 words)\n")
                     .arg(wer, 0, 'f', 1).arg(errors).arg(w.refWords);
        out() << QStringLiteral("reference   \"%1\"\n").arg(ref.join(QLatin1Char(' ')));
        out() << QStringLiteral("            %1 wrong, %2 missed, %3 invented\n")
                     .arg(w.substitutions).arg(w.deletions).arg(w.insertions);
        out() << "\n";
        if (wer < 10.0)
            out() << "  -> Good. Below about 10% the detectors have plenty to work with.\n";
        else if (wer < 25.0)
            out() << "  -> Usable for citations, marginal for quotation matching.\n";
        else
            out() << "  -> Too high. Fix the audio first, then try a larger model.\n";
    }
    out().flush();
    return 0;
}

}  // namespace

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QCoreApplication::setApplicationName(QStringLiteral("Crater"));

    QString mode, wav, model, deviceId, truth, draft;
    int  seconds = 20;
    int  repeat  = 1;
    int  window  = 0;
    bool interim = false;

    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        const QString& a = args.at(i);
        if      (a == QLatin1String("--list"))                                 mode = a;
        else if (a == QLatin1String("--record")     && i + 1 < args.size())  { mode = a; wav = args.at(++i); }
        else if (a == QLatin1String("--analyze")    && i + 1 < args.size())  { mode = a; wav = args.at(++i); }
        else if (a == QLatin1String("--transcribe") && i + 1 < args.size())  { mode = a; wav = args.at(++i); }
        else if (a == QLatin1String("--score")      && i + 1 < args.size())  { mode = QStringLiteral("--transcribe"); wav = args.at(++i); }
        else if (a == QLatin1String("--model")      && i + 1 < args.size())    model    = args.at(++i);
        else if (a == QLatin1String("--device")     && i + 1 < args.size())    deviceId = args.at(++i);
        else if (a == QLatin1String("--truth")      && i + 1 < args.size())    truth    = args.at(++i);
        else if (a == QLatin1String("--draft")      && i + 1 < args.size())    draft    = args.at(++i);
        else if (a == QLatin1String("--seconds")    && i + 1 < args.size())    seconds  = args.at(++i).toInt();
        else if (a == QLatin1String("--repeat")     && i + 1 < args.size())    repeat   = args.at(++i).toInt();
        else if (a == QLatin1String("--window")     && i + 1 < args.size())    window   = args.at(++i).toInt();
        else if (a == QLatin1String("--interim"))                              interim  = true;
    }

    if (mode == QLatin1String("--list"))     return listDevices();
    if (mode == QLatin1String("--record"))   return record(wav, deviceId, std::max(1, seconds));
    if (mode == QLatin1String("--analyze"))  return analyze(wav);
    if (mode == QLatin1String("--transcribe")) {
        if (model.isEmpty()) {
            out() << "error: --transcribe needs --model <ggml.bin>\n";
            out().flush();
            return 2;
        }
        return transcribe(wav, model, repeat, truth, draft, interim, window);
    }

    out() << "narration_bench - measure the narration audio chain\n\n"
             "  --list                                 what microphones are connected\n"
             "  --record <out.wav> [--device <id>] [--seconds 20]\n"
             "                                         capture through the real AudioTap\n"
             "  --analyze <in.wav>                     level, clipping, voiced fraction\n"
             "  --transcribe <in.wav> --model <m.bin> [--repeat 3]\n"
             "                                         what the engine hears, and how fast\n"
             "  --score <in.wav> --model <m.bin> --truth truth.txt\n"
             "                                         the same, plus word error rate\n"
             "  ... --interim [--draft <fast.bin>]     measure the live-hypothesis pass\n"
             "                                         instead of the finished-utterance one\n"
             "  ... --window <seconds>                 keep only the last N seconds, as the\n"
             "                                         interim pass does (app uses 5)\n\n"
             "Start with --list, then --record, and read the level report before\n"
             "concluding anything about the model.\n";
    out().flush();
    return 2;
}
