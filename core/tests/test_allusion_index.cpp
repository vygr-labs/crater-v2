// Narration phase 4 — the semantic path's index and gates.
// docs/narration.md §7.2 and §7.3.
//
// The embedding model is not here, and that is the point of the seam. Every
// piece this file covers is exercised with synthetic vectors that behave
// exactly as real ones do (unit length, cosine-comparable), because the parts
// that can go wrong — quantization error, file-format round-tripping, the
// brute-force scan, and the three distinctiveness gates — have nothing to do
// with which model produced the numbers.
//
// What is NOT covered here, stated plainly: whether a real bge-small
// embedding of "God loved us so much that he sent his own son to die" lands
// near John 3:16. That needs the model, and until it ships this path stays
// inert in NarrationService rather than guessing.

#include <QtTest>

#include <QCoreApplication>
#include <QDir>
#include <QTemporaryDir>

#include "narration/AllusionIndex.h"
#include "narration/AllusionMatcher.h"

using namespace crater;
using narration::AllusionIndex;
using narration::AllusionMatcher;

namespace {

// A unit vector pointing mostly along axis `axis`, with `noise` spread over
// the rest. Gives us controllable, predictable cosine relationships.
QList<float> unitAlong(int dims, int axis, float noise = 0.0f, int noiseSeed = 1)
{
    QList<float> v;
    v.resize(dims);
    for (int i = 0; i < dims; ++i)
        v[i] = (i == axis) ? 1.0f : 0.0f;

    if (noise > 0.0f) {
        // Deterministic pseudo-noise: no Math.random equivalent needed and
        // the test stays reproducible.
        quint32 s = quint32(noiseSeed) * 2654435761u;
        for (int i = 0; i < dims; ++i) {
            s = s * 1664525u + 1013904223u;
            const float r = float(int(s >> 16) % 2001 - 1000) / 1000.0f;
            v[i] += noise * r;
        }
    }

    double n = 0.0;
    for (const float x : v) n += double(x) * double(x);
    n = std::sqrt(n);
    if (n > 0.0)
        for (float& x : v) x = float(double(x) / n);
    return v;
}

float cosine(const QList<float>& a, const QList<float>& b)
{
    double d = 0.0;
    for (int i = 0; i < a.size(); ++i) d += double(a.at(i)) * double(b.at(i));
    return float(d);
}

constexpr int kDims = 384;   // bge-small-en-v1.5's width

bool hasRef(const QList<HeardReference>& refs, const QString& reference)
{
    for (const HeardReference& r : refs)
        if (r.reference == reference) return true;
    return false;
}

AllusionIndex::Entry entry(const char* book, int ch, int v, QList<float> vec)
{
    AllusionIndex::Entry e;
    e.book = QString::fromUtf8(book);
    e.chapter = ch;
    e.verse = v;
    e.vector = std::move(vec);
    return e;
}

}  // namespace

class TestAllusionIndex : public QObject
{
    Q_OBJECT

private:
    QList<AllusionIndex::Entry> makeCorpus(int n) const
    {
        QList<AllusionIndex::Entry> entries;
        entries.reserve(n);
        for (int i = 0; i < n; ++i) {
            entries.append(entry("John", 1 + i / 30, 1 + i % 30,
                                 unitAlong(kDims, i % kDims, 0.01f, i + 1)));
        }
        return entries;
    }

private slots:

    // ── Build and scan ──────────────────────────────────────────────────

    void an_empty_build_is_refused()
    {
        AllusionIndex idx;
        QString err;
        QVERIFY(!idx.build({}, QStringLiteral("m"), &err));
        QVERIFY(!err.isEmpty());
        QVERIFY(!idx.isLoaded());
    }

    // A ragged index would silently misalign every row after the bad one,
    // which is the kind of corruption that produces plausible wrong verses
    // rather than an obvious failure.
    void a_ragged_build_is_refused()
    {
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("John", 3, 16, unitAlong(kDims, 0)));
        e.append(entry("John", 3, 17, unitAlong(kDims / 2, 0)));

        QString err;
        QVERIFY(!idx.build(e, QStringLiteral("m"), &err));
        QVERIFY(err.contains(QStringLiteral("dimensions")));
        QVERIFY(!idx.isLoaded());
    }

    void search_finds_the_nearest_vector()
    {
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("Genesis", 1, 1,  unitAlong(kDims, 0)));
        e.append(entry("John",    3, 16, unitAlong(kDims, 1)));
        e.append(entry("Romans",  8, 28, unitAlong(kDims, 2)));
        QVERIFY(idx.build(e, QStringLiteral("test-model")));

        const auto hits = idx.search(unitAlong(kDims, 1), 2);
        QCOMPARE(hits.size(), 2);
        QCOMPARE(hits.first().book,    QStringLiteral("John"));
        QCOMPARE(hits.first().chapter, 3);
        QCOMPARE(hits.first().verse,   16);
        // Orthogonal neighbours, so the runner-up should be near zero.
        QVERIFY(hits.first().score > hits.at(1).score);
    }

    void search_returns_hits_best_first()
    {
        AllusionIndex idx;
        QVERIFY(idx.build(makeCorpus(200), QStringLiteral("m")));

        const auto hits = idx.search(unitAlong(kDims, 7, 0.01f, 8), 5);
        QCOMPARE(hits.size(), 5);
        for (int i = 1; i < hits.size(); ++i)
            QVERIFY2(hits.at(i - 1).score >= hits.at(i).score, "hits are not sorted");
    }

    // Quantization has to preserve enough of the geometry that an absolute
    // cosine threshold still means something. If it did not, minScore would
    // be measuring the compression rather than the similarity.
    void quantization_error_stays_small()
    {
        AllusionIndex idx;
        const QList<float> target = unitAlong(kDims, 5, 0.03f, 42);

        QList<AllusionIndex::Entry> e;
        e.append(entry("John", 3, 16, target));
        QVERIFY(idx.build(e, QStringLiteral("m")));

        // A vector's similarity to itself is exactly 1.0 before quantization.
        const auto hits = idx.search(target, 1);
        QCOMPARE(hits.size(), 1);
        const float err = std::fabs(1.0f - hits.first().score);
        qInfo() << "self-similarity error after int8 round trip:" << err;
        QVERIFY2(err < 0.01f,
                 qPrintable(QStringLiteral("int8 round trip lost %1 of cosine").arg(err)));
    }

    void quantization_preserves_relative_order()
    {
        // Three vectors at known, different angles from the query. The index
        // must rank them the same way exact float cosine does.
        const QList<float> query = unitAlong(kDims, 0);
        const QList<float> near  = unitAlong(kDims, 0, 0.20f, 3);
        const QList<float> mid   = unitAlong(kDims, 0, 0.60f, 4);
        const QList<float> far   = unitAlong(kDims, 9, 0.05f, 5);

        QVERIFY(cosine(query, near) > cosine(query, mid));
        QVERIFY(cosine(query, mid)  > cosine(query, far));

        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("A", 1, 1, far));
        e.append(entry("B", 1, 1, mid));
        e.append(entry("C", 1, 1, near));
        QVERIFY(idx.build(e, QStringLiteral("m")));

        const auto hits = idx.search(query, 3);
        QCOMPARE(hits.size(), 3);
        QCOMPARE(hits.at(0).book, QStringLiteral("C"));
        QCOMPARE(hits.at(1).book, QStringLiteral("B"));
        QCOMPARE(hits.at(2).book, QStringLiteral("A"));
    }

    void a_wrong_sized_query_returns_nothing()
    {
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("John", 3, 16, unitAlong(kDims, 0)));
        QVERIFY(idx.build(e, QStringLiteral("m")));

        // Never compare a padded or truncated vector — the result would be a
        // confident number derived from nothing.
        QVERIFY(idx.search(unitAlong(kDims / 2, 0), 1).isEmpty());
        QVERIFY(idx.search({}, 1).isEmpty());
    }

    // ── File format ─────────────────────────────────────────────────────

    void save_and_load_round_trip()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = QDir(dir.path()).filePath(QStringLiteral("verses.crai"));

        AllusionIndex a;
        QVERIFY(a.build(makeCorpus(500), QStringLiteral("bge-small-en-v1.5")));
        QString err;
        QVERIFY2(a.save(path, &err), qPrintable(err));

        AllusionIndex b;
        QVERIFY2(b.load(path, QStringLiteral("bge-small-en-v1.5"), &err), qPrintable(err));

        QCOMPARE(b.count(),      a.count());
        QCOMPARE(b.dimensions(), a.dimensions());
        QCOMPARE(b.modelId(),    QStringLiteral("bge-small-en-v1.5"));

        // Identical rankings AND identical scores: the file must not be a
        // lossy step on top of the quantization that already happened.
        const QList<float> q = unitAlong(kDims, 11, 0.01f, 12);
        const auto ha = a.search(q, 4);
        const auto hb = b.search(q, 4);
        QCOMPARE(hb.size(), ha.size());
        for (int i = 0; i < ha.size(); ++i) {
            QCOMPARE(hb.at(i).book,    ha.at(i).book);
            QCOMPARE(hb.at(i).chapter, ha.at(i).chapter);
            QCOMPARE(hb.at(i).verse,   ha.at(i).verse);
            QCOMPARE(hb.at(i).score,   ha.at(i).score);
        }
    }

    // The dangerous failure: two models' vector spaces are unrelated, so
    // searching one with the other's query returns high-scoring arbitrary
    // verses — output indistinguishable from a working system.
    void a_model_mismatch_is_refused()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = QDir(dir.path()).filePath(QStringLiteral("verses.crai"));

        AllusionIndex a;
        QVERIFY(a.build(makeCorpus(20), QStringLiteral("model-one")));
        QVERIFY(a.save(path));

        AllusionIndex b;
        QString err;
        QVERIFY(!b.load(path, QStringLiteral("model-two"), &err));
        QVERIFY(err.contains(QStringLiteral("model-one")));
        QVERIFY(err.contains(QStringLiteral("Rebuild")));
        QVERIFY(!b.isLoaded());

        // An empty expectation accepts whatever the file declares.
        QVERIFY(b.load(path, QString(), &err));
        QCOMPARE(b.modelId(), QStringLiteral("model-one"));
    }

    void garbage_is_rejected_rather_than_interpreted()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = QDir(dir.path()).filePath(QStringLiteral("junk.crai"));

        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("not an index, just some bytes that are long enough to read a header from");
        f.close();

        AllusionIndex idx;
        QString err;
        QVERIFY(!idx.load(path, QString(), &err));
        QVERIFY(!err.isEmpty());
        QVERIFY(!idx.isLoaded());
    }

    void a_truncated_index_is_rejected()
    {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = QDir(dir.path()).filePath(QStringLiteral("cut.crai"));

        AllusionIndex a;
        QVERIFY(a.build(makeCorpus(100), QStringLiteral("m")));
        QVERIFY(a.save(path));

        // Chop the tail: header and book table survive, vectors do not.
        QFile f(path);
        QVERIFY(f.open(QIODevice::ReadWrite));
        QVERIFY(f.resize(f.size() / 3));
        f.close();

        AllusionIndex b;
        QString err;
        QVERIFY(!b.load(path, QString(), &err));
        QVERIFY(!b.isLoaded());
    }

    void a_missing_file_is_not_a_crash()
    {
        AllusionIndex idx;
        QString err;
        QVERIFY(!idx.load(QStringLiteral("Z:/no/such/index.crai"), QString(), &err));
        QVERIFY(!err.isEmpty());
        QVERIFY(idx.search(unitAlong(kDims, 0), 1).isEmpty());
    }

    // ── Scan cost ───────────────────────────────────────────────────────

    // docs/narration.md §7.2 claims a full scan is a couple of milliseconds
    // and uses that to justify having no ANN index at all. That claim should
    // be measured, not asserted in prose.
    void a_full_corpus_scan_is_fast()
    {
        AllusionIndex idx;
        QVERIFY(idx.build(makeCorpus(31102), QStringLiteral("m")));   // real corpus size
        QCOMPARE(idx.count(), 31102);

        const QList<float> q = unitAlong(kDims, 3, 0.02f, 9);
        idx.search(q, 2);   // warm

        QElapsedTimer t;
        t.start();
        for (int i = 0; i < 20; ++i) idx.search(q, 2);
        const double ms = double(t.elapsed()) / 20.0;

        qInfo().noquote() << QStringLiteral("flat scan over 31,102 x %1 int8: %2 ms")
                                 .arg(kDims).arg(ms, 0, 'f', 2);
        QVERIFY2(ms < 25.0,
                 qPrintable(QStringLiteral("%1 ms; the no-ANN argument rests on this "
                                           "being cheap").arg(ms)));
    }

    // ── The three gates ─────────────────────────────────────────────────

    void an_unconfigured_matcher_is_inert()
    {
        AllusionMatcher m;
        QVERIFY(!m.isReady());
        QVERIFY(m.match(QStringLiteral("god loved us so much that he sent his own son "
                                       "to die for our sins"), 0).isEmpty());

        // An index but no embedder is still inert, and vice versa.
        AllusionIndex idx;
        QVERIFY(idx.build(makeCorpus(10), QStringLiteral("m")));
        m.setIndex(&idx);
        QVERIFY(!m.isReady());
    }

    void a_confident_isolated_match_is_reported_as_possible()
    {
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("John",   3, 16, unitAlong(kDims, 0)));
        e.append(entry("Romans", 5,  8, unitAlong(kDims, 40)));   // far away
        QVERIFY(idx.build(e, QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([&](const QString&) { return unitAlong(kDims, 0, 0.05f, 2); });

        const auto refs = m.match(
            QStringLiteral("god loved us so much that he sent his own son to die"), 500);

        QCOMPARE(refs.size(), 1);
        QCOMPARE(refs.first().reference, QStringLiteral("John 3:16"));
        QCOMPARE(refs.first().kind,      QStringLiteral("allusion"));
        QCOMPARE(refs.first().atMs,      qint64(500));

        // The property that lets this path exist at all. TrustGate refuses to
        // project "possible" in any mode.
        QCOMPARE(refs.first().tier, QStringLiteral("possible"));
    }

    // Gate 1. Runs before the embedding, so a short phrase costs nothing.
    void a_short_phrase_never_reaches_the_model()
    {
        AllusionIndex idx;
        QVERIFY(idx.build(makeCorpus(10), QStringLiteral("m")));

        bool embedded = false;
        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([&](const QString&) { embedded = true; return unitAlong(kDims, 0); });

        QVERIFY(m.match(QStringLiteral("we should love each other"), 0).isEmpty());
        QVERIFY2(!embedded, "the content floor must gate before the embedding cost");
    }

    // Gate 2. A distant nearest neighbour is not an allusion, it is just the
    // closest thing in a corpus that had to return something.
    void a_distant_best_match_is_rejected()
    {
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("John", 3, 16, unitAlong(kDims, 0)));
        QVERIFY(idx.build(e, QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        // Nearly orthogonal to the only verse present.
        m.setEmbedder([&](const QString&) { return unitAlong(kDims, 50, 0.02f, 6); });

        QVERIFY(m.match(QStringLiteral("the youth group is meeting on wednesday evening "
                                       "in the fellowship hall downstairs"), 0).isEmpty());
    }

    // Gate 3, and the one no absolute threshold can replace. A LARGE crowd of
    // equally-near verses means the phrase expresses a theme the canon shares
    // rather than a paraphrase of anything in particular.
    void a_crowded_neighbourhood_is_rejected()
    {
        const QList<float> base = unitAlong(kDims, 0);

        // Twelve verses all clustered around the query. Nothing here
        // identifies anything — this is what generic religious phrasing looks
        // like in embedding space.
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        for (int i = 0; i < 12; ++i)
            e.append(entry("John", 13, 20 + i, unitAlong(kDims, 0, 0.02f, 11 + i)));
        QVERIFY(idx.build(e, QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([&](const QString&) { return base; });

        // Precondition: they clear the absolute threshold, so only the
        // cluster-size rule can be what rejects them.
        const auto hits = idx.search(base, m.config().probeDepth);
        QVERIFY(hits.size() > m.config().maxCluster);
        QVERIFY(hits.first().score >= m.config().minScore);
        QVERIFY(hits.at(m.config().maxCluster).score >= m.config().minScore);

        QVERIFY2(m.match(QStringLiteral("we ought to love one another the way that he "
                                        "first loved every one of us"), 0).isEmpty(),
                 "a phrase equally near ten verses is a paraphrase of none of them");
    }

    // The other half of the same rule, and the reason it counts neighbours
    // instead of measuring a top-2 gap. Scripture restates its central ideas
    // in a handful of places; when a paraphrase matches two or three verses
    // that are all genuinely right, the operator should get all of them —
    // this tier only ever populates a queue, never the projector.
    void a_small_cluster_yields_every_member()
    {
        const QList<float> base = unitAlong(kDims, 0);

        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("1 John", 4,  9, unitAlong(kDims, 0, 0.02f, 11)));
        e.append(entry("Romans", 5,  8, unitAlong(kDims, 0, 0.02f, 12)));
        e.append(entry("John",   3, 16, unitAlong(kDims, 0, 0.02f, 13)));
        e.append(entry("Psalms", 23, 1, unitAlong(kDims, 60, 0.02f, 14)));   // far away
        QVERIFY(idx.build(e, QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([&](const QString&) { return base; });

        const auto refs = m.match(
            QStringLiteral("god loved us so much that he sent his own son to die so that "
                           "we could live with him"), 0);

        QCOMPARE(refs.size(), 3);
        QVERIFY(hasRef(refs, QStringLiteral("1 John 4:9")));
        QVERIFY(hasRef(refs, QStringLiteral("Romans 5:8")));
        QVERIFY(hasRef(refs, QStringLiteral("John 3:16")));
        // The distant verse is not part of the cluster.
        QVERIFY(!hasRef(refs, QStringLiteral("Psalms 23:1")));
        for (const HeardReference& r : refs)
            QCOMPARE(r.tier, QStringLiteral("possible"));
    }

    // The gospel case, and the reason maxCluster is 7 rather than 3.
    //
    // "God loved us so much that he sent his own son to die" is the example
    // §2 opens with, and against the real index it lands on a crowd of seven —
    // 1 John 4:9, Romans 5:8, John 3:16 and four more. Every one of them is a
    // correct answer; scripture simply states this in seven places. A gate
    // tuned to reject crowds rejected the feature's own headline example, and
    // "your paraphrase was too central to the faith" is not a defensible
    // reason to show the operator nothing.
    //
    // So the whole cluster is offered and the operator picks. That is only
    // safe because of what this tier is: TrustGate refuses to project
    // "possible" in any mode, so seven suggestions is seven chips in a queue,
    // never seven verses on the screen.
    void a_seven_verse_cluster_yields_all_seven()
    {
        const QList<float> base = unitAlong(kDims, 0);

        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("1 John",        4,  9, unitAlong(kDims, 0, 0.02f, 21)));
        e.append(entry("Romans",        5,  8, unitAlong(kDims, 0, 0.02f, 22)));
        e.append(entry("John",          3, 16, unitAlong(kDims, 0, 0.02f, 23)));
        e.append(entry("1 John",        4, 10, unitAlong(kDims, 0, 0.02f, 24)));
        e.append(entry("Titus",         3,  4, unitAlong(kDims, 0, 0.02f, 25)));
        e.append(entry("Ephesians",     2,  4, unitAlong(kDims, 0, 0.02f, 26)));
        e.append(entry("1 Thessalonians", 5, 10, unitAlong(kDims, 0, 0.02f, 27)));
        e.append(entry("Psalms",       23,  1, unitAlong(kDims, 60, 0.02f, 28)));  // far away
        QVERIFY(idx.build(e, QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([&](const QString&) { return base; });

        // The invariant that makes the gate above mean anything: admitting a
        // cluster of seven and then emitting three would hand the operator an
        // arbitrary subset of the answer.
        QVERIFY2(m.config().maxEmits >= m.config().maxCluster,
                 "maxEmits below maxCluster silently truncates an accepted cluster");

        const auto refs = m.match(
            QStringLiteral("god loved us so much that he sent his own son to die so that "
                           "we could live with him"), 0);

        QCOMPARE(refs.size(), 7);
        QVERIFY(hasRef(refs, QStringLiteral("1 John 4:9")));
        QVERIFY(hasRef(refs, QStringLiteral("Romans 5:8")));
        QVERIFY(hasRef(refs, QStringLiteral("John 3:16")));
        QVERIFY(!hasRef(refs, QStringLiteral("Psalms 23:1")));
        for (const HeardReference& r : refs)
            QCOMPARE(r.tier, QStringLiteral("possible"));
    }

    void an_embedder_returning_nothing_is_survivable()
    {
        AllusionIndex idx;
        QVERIFY(idx.build(makeCorpus(10), QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([](const QString&) { return QList<float>(); });

        QVERIFY(m.match(QStringLiteral("god loved us so much that he sent his own son "
                                       "to die for our sins"), 0).isEmpty());
    }

    void overlapping_windows_do_not_emit_the_same_verse_twice()
    {
        AllusionIndex idx;
        QList<AllusionIndex::Entry> e;
        e.append(entry("John",   3, 16, unitAlong(kDims, 0)));
        e.append(entry("Romans", 5,  8, unitAlong(kDims, 40)));
        QVERIFY(idx.build(e, QStringLiteral("m")));

        AllusionMatcher m;
        m.setIndex(&idx);
        m.setEmbedder([&](const QString&) { return unitAlong(kDims, 0, 0.05f, 2); });

        // Long enough to slide several windows, every one of which resolves
        // to the same verse.
        const auto refs = m.match(
            QStringLiteral("god loved us so much that he sent his own son to die for our "
                           "sins because he wanted every single one of us to be able to "
                           "come home to him again and live with him forever and ever"), 0);
        QCOMPARE(refs.size(), 1);
    }
};

QTEST_MAIN(TestAllusionIndex)
#include "test_allusion_index.moc"
