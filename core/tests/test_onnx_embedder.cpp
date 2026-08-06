// The allusion path's embedder, against the real bge-small-en-v1.5 model.
//
// This is the test that can catch what nothing else can. Tokenization,
// pooling mode and normalization are each individually plausible when wrong,
// and each produces a well-formed 384-dimension unit vector either way. The
// only way to tell a correct embedding from a confidently wrong one is to ask
// whether the geometry means anything: does a paraphrase of John 3:16 land
// closer to John 3:16 than to a verse about a shepherd?
//
// If CLS pooling were silently swapped for mean pooling, or the WordPiece ids
// were off, every assertion about shape and length below would still pass and
// the semantic ones would not.
//
// Skips with a reason when the model is not installed. The model is ~127 MB
// and operator-supplied, exactly like the whisper model.

#include <QtTest>

#include <QCoreApplication>
#include <QDir>
#include <QFile>

#include "db/DbPaths.h"
#include "narration/AllusionIndex.h"
#include "narration/AllusionMatcher.h"
#include "narration/OnnxEmbedder.h"

using namespace crater;
using narration::AllusionIndex;
using narration::AllusionMatcher;
using narration::OnnxEmbedder;

namespace {

QString modelPath()
{
    return QDir(db::DbPaths::dataDir())
        .filePath(QStringLiteral("models/bge-small-en-v1.5.onnx"));
}

float cosine(const QList<float>& a, const QList<float>& b)
{
    if (a.size() != b.size() || a.isEmpty()) return -2.0f;
    double d = 0.0;
    for (int i = 0; i < a.size(); ++i) d += double(a.at(i)) * double(b.at(i));
    return float(d);
}

// Verse texts (KJV), used as the "index side" of every comparison.
constexpr const char* kJohn316 =
    "For God so loved the world, that he gave his only begotten Son, that "
    "whosoever believeth in him should not perish, but have everlasting life.";
constexpr const char* kPsalm231 =
    "The LORD is my shepherd; I shall not want.";
constexpr const char* kGenesis11 =
    "In the beginning God created the heaven and the earth.";
constexpr const char* kPhil413 =
    "I can do all things through Christ which strengtheneth me.";

}  // namespace

class TestOnnxEmbedder : public QObject
{
    Q_OBJECT

private:
    OnnxEmbedder emb;
    bool         ready = false;

    void requireModel()
    {
        if (!ready) QSKIP("bge-small-en-v1.5.onnx is not installed; skipping embedder tests");
    }

private slots:
    void initTestCase()
    {
        if (!emb.isReady() && QFile::exists(modelPath())) {
            QString err;
            if (!emb.load(modelPath(), &err))
                qWarning().noquote() << "embedder load failed:" << err;
        }
        ready = emb.isReady();
        if (!ready)
            qInfo().noquote() << "no embedder at" << modelPath();
    }

    void the_build_reports_its_capability_honestly()
    {
        // Whatever the build options, modelId and dimensions are constant so
        // an index built by one build is readable by another.
        QCOMPARE(emb.dimensions(), 384);
        QVERIFY(emb.modelId().startsWith(QStringLiteral("bge-small-en-v1.5")));

        // Deliberately NOT branching on CRATER_WITH_EMBEDDINGS. That define
        // is PRIVATE to crater-core, so this translation unit never sees it
        // even when the library it links was built with the real embedder —
        // a test keyed off it would assert the opposite of reality.
        //
        // Runtime state is the honest question anyway: a bad path must fail
        // with a reason, in every build.
        OnnxEmbedder fresh;
        QVERIFY(!fresh.isReady());

        QString err;
        QVERIFY(!fresh.load(QStringLiteral("Z:/no/such/model.onnx"), &err));
        QVERIFY2(!err.isEmpty(), "a failed load must say why");
        QVERIFY(!fresh.isReady());
        QVERIFY(fresh.embedOne(QStringLiteral("anything")).isEmpty());
    }

    // ── Shape and normalization ─────────────────────────────────────────

    void an_embedding_is_384_dimensions_and_unit_length()
    {
        requireModel();
        const QList<float> v = emb.embedOne(QStringLiteral("For God so loved the world"));
        QCOMPARE(v.size(), 384);

        double n = 0.0;
        for (const float x : v) n += double(x) * double(x);
        n = std::sqrt(n);
        QVERIFY2(std::fabs(n - 1.0) < 1e-4,
                 qPrintable(QStringLiteral("norm is %1, AllusionIndex assumes unit length")
                                .arg(n)));
    }

    void embedding_is_deterministic()
    {
        requireModel();
        const QString s = QStringLiteral("The LORD is my shepherd");
        QCOMPARE(cosine(emb.embedOne(s), emb.embedOne(s)), 1.0f);
    }

    void a_batch_matches_one_at_a_time()
    {
        requireModel();
        const QStringList texts = {
            QString::fromUtf8(kJohn316),
            QString::fromUtf8(kPsalm231),
            QString::fromUtf8(kGenesis11)
        };
        const auto batch = emb.embed(texts);
        QCOMPARE(batch.size(), texts.size());
        for (int i = 0; i < texts.size(); ++i) {
            QCOMPARE(batch.at(i).size(), 384);
            QVERIFY(cosine(batch.at(i), emb.embedOne(texts.at(i))) > 0.9999f);
        }
    }

    void empty_text_still_produces_a_usable_vector()
    {
        requireModel();
        // [CLS] [SEP] with nothing between is a valid sequence; it must not
        // crash or return a zero vector the index would silently skip.
        const QList<float> v = emb.embedOne(QString());
        QCOMPARE(v.size(), 384);
    }

    // ── The semantic checks ─────────────────────────────────────────────
    //
    // These are what prove the tokenizer, CLS pooling and normalization are
    // right *together*. Every one of them fails if any single piece is wrong,
    // and none of them can be satisfied by accident.

    void a_paraphrase_lands_nearest_the_verse_it_paraphrases()
    {
        requireModel();

        // docs/narration.md §2's own example of an allusion.
        const QList<float> said =
            emb.embedOne(QStringLiteral("God loved us so much that he sent his own son to die"));

        const float toJohn    = cosine(said, emb.embedOne(QString::fromUtf8(kJohn316)));
        const float toPsalm   = cosine(said, emb.embedOne(QString::fromUtf8(kPsalm231)));
        const float toGenesis = cosine(said, emb.embedOne(QString::fromUtf8(kGenesis11)));
        const float toPhil    = cosine(said, emb.embedOne(QString::fromUtf8(kPhil413)));

        qInfo().noquote() << QStringLiteral(
            "paraphrase similarity  John 3:16=%1  Psalm 23:1=%2  Gen 1:1=%3  Phil 4:13=%4")
                .arg(toJohn, 0, 'f', 3).arg(toPsalm, 0, 'f', 3)
                .arg(toGenesis, 0, 'f', 3).arg(toPhil, 0, 'f', 3);

        QVERIFY2(toJohn > toPsalm && toJohn > toGenesis && toJohn > toPhil,
                 "a paraphrase of John 3:16 must be nearest John 3:16");
        QVERIFY2(toJohn > 0.6f,
                 qPrintable(QStringLiteral("similarity to the paraphrased verse is only %1")
                                .arg(toJohn)));
    }

    void a_second_paraphrase_also_resolves()
    {
        requireModel();
        const QList<float> said =
            emb.embedOne(QStringLiteral("the Lord takes care of me like a shepherd "
                                        "so there is nothing I need"));

        const float toPsalm = cosine(said, emb.embedOne(QString::fromUtf8(kPsalm231)));
        const float toJohn  = cosine(said, emb.embedOne(QString::fromUtf8(kJohn316)));

        qInfo().noquote() << QStringLiteral("shepherd paraphrase  Psalm 23:1=%1  John 3:16=%2")
                                 .arg(toPsalm, 0, 'f', 3).arg(toJohn, 0, 'f', 3);
        QVERIFY(toPsalm > toJohn);
    }

    // Announcements are the false-positive risk this whole path is gated
    // against. They should sit far from every verse.
    void ordinary_speech_is_far_from_scripture()
    {
        requireModel();
        const QList<float> said =
            emb.embedOne(QStringLiteral("the youth group is meeting on wednesday evening "
                                        "in the fellowship hall downstairs"));

        const QStringList verses = { QString::fromUtf8(kJohn316), QString::fromUtf8(kPsalm231),
                                     QString::fromUtf8(kGenesis11), QString::fromUtf8(kPhil413) };
        float worst = -2.0f;
        for (const QString& v : verses)
            worst = std::max(worst, cosine(said, emb.embedOne(v)));

        qInfo().noquote() << QStringLiteral("announcement's closest verse: %1")
                                 .arg(worst, 0, 'f', 3);
        QVERIFY2(worst < 0.6f,
                 qPrintable(QStringLiteral("announcements sit at %1 from scripture, which "
                                           "would defeat the absolute threshold")
                                .arg(worst)));
    }

    // ── End to end through the real index ───────────────────────────────

    void the_whole_allusion_path_resolves_a_paraphrase()
    {
        requireModel();

        // A miniature index built exactly the way the real one will be:
        // real embeddings of real verse text, quantized to int8, scanned by
        // AllusionIndex, gated by AllusionMatcher.
        struct V { const char* book; int ch; int v; const char* text; };
        const QList<V> verses = {
            { "John",        3, 16, kJohn316  },
            { "Psalms",     23,  1, kPsalm231 },
            { "Genesis",     1,  1, kGenesis11 },
            { "Philippians", 4, 13, kPhil413  },
        };

        QList<AllusionIndex::Entry> entries;
        for (const V& v : verses) {
            AllusionIndex::Entry e;
            e.book = QString::fromUtf8(v.book);
            e.chapter = v.ch;
            e.verse = v.v;
            e.vector = emb.embedOne(QString::fromUtf8(v.text));
            QCOMPARE(e.vector.size(), 384);
            entries.append(e);
        }

        AllusionIndex idx;
        QString err;
        QVERIFY2(idx.build(entries, emb.modelId(), &err), qPrintable(err));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([this](const QString& t) { return emb.embedOne(t); });
        QVERIFY(m.isReady());

        const auto refs =
            m.match(QStringLiteral("god loved us so much that he sent his own son to die "
                                   "so that we could live with him forever"), 0);

        QVERIFY2(!refs.isEmpty(), "the gates rejected a genuine paraphrase");
        QCOMPARE(refs.first().reference, QStringLiteral("John 3:16"));
        QCOMPARE(refs.first().kind,      QStringLiteral("allusion"));
        // Never anything but "possible", however good the match looked.
        QCOMPARE(refs.first().tier,      QStringLiteral("possible"));
    }

    void the_whole_allusion_path_stays_quiet_on_announcements()
    {
        requireModel();

        struct V { const char* book; int ch; int v; const char* text; };
        const QList<V> verses = {
            { "John",        3, 16, kJohn316  },
            { "Psalms",     23,  1, kPsalm231 },
            { "Genesis",     1,  1, kGenesis11 },
            { "Philippians", 4, 13, kPhil413  },
        };

        QList<AllusionIndex::Entry> entries;
        for (const V& v : verses) {
            AllusionIndex::Entry e;
            e.book = QString::fromUtf8(v.book);
            e.chapter = v.ch; e.verse = v.v;
            e.vector = emb.embedOne(QString::fromUtf8(v.text));
            entries.append(e);
        }

        AllusionIndex idx;
        QVERIFY(idx.build(entries, emb.modelId()));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([this](const QString& t) { return emb.embedOne(t); });

        const QStringList speech = {
            QStringLiteral("the youth group is meeting on wednesday evening in the hall"),
            QStringLiteral("there are envelopes in the back if you would like to give today"),
            QStringLiteral("please remember to sign up for the church picnic next weekend"),
            QStringLiteral("good morning everybody it is wonderful to see you all here"),
        };
        for (const QString& s : speech) {
            const auto refs = m.match(s, 0);
            if (!refs.isEmpty()) {
                QFAIL(qPrintable(QStringLiteral("announcement fired: \"%1\" -> %2")
                                     .arg(s, refs.first().reference)));
            }
        }
    }

    // §9's budget for a query embedding. This runs once per utterance on the
    // detection path, so it is part of speech-to-screen latency.
    void embedding_one_utterance_is_fast_enough()
    {
        requireModel();
        const QString s =
            QStringLiteral("god loved us so much that he sent his own son to die for us");
        emb.embedOne(s);   // warm

        QElapsedTimer t;
        t.start();
        for (int i = 0; i < 10; ++i) emb.embedOne(s);
        const double ms = double(t.elapsed()) / 10.0;

        qInfo().noquote() << QStringLiteral("query embedding: %1 ms").arg(ms, 0, 'f', 1);
        QVERIFY2(ms < 250.0,
                 qPrintable(QStringLiteral("%1 ms per query embedding").arg(ms)));
    }
};

// Not QTEST_MAIN: DbPaths resolves the model location through
// QStandardPaths::AppDataLocation, which needs the organisation and
// application names. Without them these tests would look in a directory named
// after the test binary, find nothing, and skip green.
int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QCoreApplication::setApplicationName(QStringLiteral("Crater"));

    TestOnnxEmbedder tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_onnx_embedder.moc"
