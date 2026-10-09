// Tests for DeepgramRecognizer's message assembly (docs/narration.md §7.4).
//
// Run via CTest: `ctest --test-dir <build-dir> -R deepgram_recognizer --output-on-failure`
//
// Deepgram answers a stream with three kinds of message that matter: interim
// Results (a guess, replaced by the next one), final Results (a stretch of
// speech that will not change), and the end of an utterance (speech_final on a
// Results message, or a separate UtteranceEnd when room noise hides the
// pause). Getting the assembly wrong loses words, doubles them, or sends half
// a sentence to the detectors as if it were the whole one. All of that is
// decided by handleMessage(), so these tests replay messages into it. No
// socket, no key, no network.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QSignalSpy>
#include <QTest>

#include "narration/DeepgramRecognizer.h"

using crater::narration::DeepgramRecognizer;

namespace {

QString results(const QString& transcript, double start, double duration,
                bool isFinal, bool speechFinal)
{
    QJsonObject alt;
    alt.insert(QStringLiteral("transcript"), transcript);
    QJsonObject channel;
    channel.insert(QStringLiteral("alternatives"), QJsonArray{ alt });

    QJsonObject o;
    o.insert(QStringLiteral("type"), QStringLiteral("Results"));
    o.insert(QStringLiteral("start"), start);
    o.insert(QStringLiteral("duration"), duration);
    o.insert(QStringLiteral("is_final"), isFinal);
    o.insert(QStringLiteral("speech_final"), speechFinal);
    o.insert(QStringLiteral("channel"), channel);
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString utteranceEnd()
{
    return QStringLiteral("{\"type\":\"UtteranceEnd\",\"last_word_end\":3.1}");
}

}  // namespace

class TestDeepgramRecognizer : public QObject
{
    Q_OBJECT

private slots:
    // The common case: guesses while speaking, then one finished sentence.
    void interim_then_final_gives_one_utterance()
    {
        DeepgramRecognizer r;
        QSignalSpy partial(&r, &DeepgramRecognizer::partial);
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(results(QStringLiteral("turn to"), 0.5, 0.6, false, false));
        r.handleMessage(results(QStringLiteral("turn to john three"), 0.5, 1.4, false, false));
        r.handleMessage(results(QStringLiteral("Turn to John 3:16."), 0.5, 2.0, true, true));

        QCOMPARE(partial.count(), 2);
        QCOMPARE(partial.at(1).at(0).toString(), QStringLiteral("turn to john three"));
        QCOMPARE(final.count(), 1);
        QCOMPARE(final.at(0).at(0).toString(), QStringLiteral("Turn to John 3:16."));
        // Stamped at the start of the utterance, on the session clock.
        QCOMPARE(final.at(0).at(1).toLongLong(), 500);
    }

    // Deepgram finalizes stretches of a long sentence before deciding the
    // speaker has finished. The detectors must get the whole sentence once.
    void finalized_pieces_join_into_one_utterance()
    {
        DeepgramRecognizer r;
        QSignalSpy partial(&r, &DeepgramRecognizer::partial);
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(results(QStringLiteral("Turn with me to"), 1.0, 1.0, true, false));
        r.handleMessage(results(QStringLiteral("first Corinthians"), 2.0, 1.0, false, false));
        r.handleMessage(results(QStringLiteral("first Corinthians 13:4."), 2.0, 1.5, true, true));

        QCOMPARE(final.count(), 1);
        QCOMPARE(final.at(0).at(0).toString(),
                 QStringLiteral("Turn with me to first Corinthians 13:4."));
        QCOMPARE(final.at(0).at(1).toLongLong(), 1000);

        // The interim guess shows the whole sentence so far, not only its tail.
        bool sawWhole = false;
        for (const auto& args : partial)
            if (args.at(0).toString() == QStringLiteral("Turn with me to first Corinthians"))
                sawWhole = true;
        QVERIFY(sawWhole);
    }

    // Room noise can keep speech_final from ever arriving. UtteranceEnd is
    // the backstop, and it must flush what was finalized.
    void utterance_end_flushes_without_speech_final()
    {
        DeepgramRecognizer r;
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(results(QStringLiteral("Romans 8:28."), 0.0, 1.2, true, false));
        QCOMPARE(final.count(), 0);
        r.handleMessage(utteranceEnd());
        QCOMPARE(final.count(), 1);
        QCOMPARE(final.at(0).at(0).toString(), QStringLiteral("Romans 8:28."));
    }

    // speech_final and then UtteranceEnd for the same sentence must not send
    // it twice, or the second copy lands as a duplicate in the log at best.
    void utterance_end_after_speech_final_does_nothing()
    {
        DeepgramRecognizer r;
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(results(QStringLiteral("John 3:16."), 0.0, 1.0, true, true));
        r.handleMessage(utteranceEnd());
        QCOMPARE(final.count(), 1);
    }

    // Silence produces empty Results. They are not utterances.
    void empty_results_are_ignored()
    {
        DeepgramRecognizer r;
        QSignalSpy partial(&r, &DeepgramRecognizer::partial);
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(results(QString(), 0.0, 1.0, false, false));
        r.handleMessage(results(QString(), 0.0, 1.0, true, true));
        r.handleMessage(utteranceEnd());
        QCOMPARE(partial.count(), 0);
        QCOMPARE(final.count(), 0);
    }

    // Two sentences in a row each start their own clock.
    void consecutive_utterances_are_stamped_separately()
    {
        DeepgramRecognizer r;
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(results(QStringLiteral("Good morning."), 0.0, 1.0, true, true));
        r.handleMessage(results(QStringLiteral("Turn to Psalm 23."), 4.0, 1.5, true, true));
        QCOMPARE(final.count(), 2);
        QCOMPARE(final.at(0).at(1).toLongLong(), 0);
        QCOMPARE(final.at(1).at(1).toLongLong(), 4000);
    }

    // Anything that isn't a message we know is ignored, not misread.
    void unknown_and_malformed_messages_are_ignored()
    {
        DeepgramRecognizer r;
        QSignalSpy partial(&r, &DeepgramRecognizer::partial);
        QSignalSpy final(&r, &DeepgramRecognizer::transcribed);

        r.handleMessage(QStringLiteral("{\"type\":\"Metadata\",\"request_id\":\"x\"}"));
        r.handleMessage(QStringLiteral("{\"type\":\"SpeechStarted\",\"timestamp\":1.0}"));
        r.handleMessage(QStringLiteral("not json at all"));
        r.handleMessage(QStringLiteral("{\"type\":\"Results\"}"));
        QCOMPARE(partial.count(), 0);
        QCOMPARE(final.count(), 0);
    }

    // No key means no connection attempt and a message that says what to do.
    void loading_without_a_key_explains_itself()
    {
        DeepgramRecognizer r;
        QString error;
        QVERIFY(!r.load(QStringLiteral("   "), &error));
        QVERIFY(error.contains(QStringLiteral("API key")));
        QVERIFY(!r.isLoaded());
    }
};

QTEST_GUILESS_MAIN(TestDeepgramRecognizer)
#include "test_deepgram_recognizer.moc"
