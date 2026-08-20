// Builds the allusion index: every verse of one translation, embedded once
// and written to a .crai file that ships beside the Bible DB.
// docs/narration.md §7.2.
//
// A developer tool, not part of the application. It runs once per model
// change, takes tens of minutes, and its output is a shipped asset. Building
// it into crater.exe would put a 130 MB model and a batch embedding loop
// inside a program whose job is to put words on a screen.
//
//   build_allusion_index --model <path.onnx> [--translation KJV] [--out <path.crai>]
//   build_allusion_index --model <path.onnx> --compare
//
// --compare answers the question the builder has to settle before it runs:
// WHICH translation should be embedded. Only one is, because identification
// returns coordinates and the operator's own translation supplies the text
// for display (§11) — so the choice is free, and should be made on evidence.

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QTextStream>

#include "crater/BibleService.h"
#include "db/DbPaths.h"
#include "narration/AllusionIndex.h"
#include "narration/AllusionMatcher.h"
#include "narration/OnnxEmbedder.h"

using namespace crater;
using narration::AllusionIndex;
using narration::AllusionMatcher;
using narration::OnnxEmbedder;

namespace {

QTextStream& out()
{
    static QTextStream s(stdout);
    return s;
}

float cosine(const QList<float>& a, const QList<float>& b)
{
    if (a.size() != b.size() || a.isEmpty()) return -2.0f;
    double d = 0.0;
    for (int i = 0; i < a.size(); ++i) d += double(a.at(i)) * double(b.at(i));
    return float(d);
}

// Does modern spoken paraphrase sit closer to a modern translation's wording
// than to the King James'? bge-small was trained on contemporary English, and
// a preacher paraphrases in contemporary English, so archaic phrasing costs
// similarity on both sides of the comparison. Worth knowing rather than
// assuming, since the index only holds one translation.
int compareTranslations(BibleService& bible, OnnxEmbedder& emb)
{
    struct Probe { const char* said; const char* book; int ch; int v; };
    const QList<Probe> probes = {
        { "god loved us so much that he sent his own son to die",              "John",    3, 16 },
        { "the lord takes care of me like a shepherd so there is nothing i need", "Psalms", 23, 1 },
        { "i can handle anything because christ gives me the strength",        "Philippians", 4, 13 },
        { "everything that happens works out for good for people who love god", "Romans",  8, 28 },
        { "do not worry about tomorrow because tomorrow will worry about itself", "Matthew", 6, 34 },
    };

    const auto translations = bible.translations();
    out() << "\ncomparing " << translations.size() << " translations over "
          << probes.size() << " paraphrases\n\n";

    QList<QPair<double, QString>> ranked;

    for (const auto& t : translations) {
        double total = 0.0;
        int    n     = 0;
        for (const Probe& p : probes) {
            const Verse verse = bible.verse(t.code, QString::fromUtf8(p.book), p.ch, p.v);
            if (verse.text.isEmpty()) continue;
            const float c = cosine(emb.embedOne(QString::fromUtf8(p.said)),
                                   emb.embedOne(verse.text));
            total += double(c);
            ++n;
        }
        if (n == 0) continue;
        ranked.append(qMakePair(total / n, t.code));
    }

    std::sort(ranked.begin(), ranked.end(),
              [](const auto& a, const auto& b) { return a.first > b.first; });

    for (const auto& r : ranked)
        out() << QStringLiteral("  %1  %2\n").arg(r.second, -10).arg(r.first, 0, 'f', 4);
    out() << "\nhigher is better: the translation whose wording sits closest to how "
             "people actually paraphrase it.\n";
    out().flush();
    return 0;
}

// The two corpora every gate decision is measured against. Shared by
// --calibrate (which prints raw geometry) and --gates (which prints what the
// shipping matcher actually does with it), because a calibration mode that
// drifts from the code it calibrates is worse than none.
QStringList paraphraseProbes()
{
    return {
        QStringLiteral("god loved us so much that he sent his own son to die so we could live"),
        QStringLiteral("the lord takes care of me like a shepherd so there is nothing that i need"),
        QStringLiteral("i can handle anything at all because christ is the one giving me strength"),
        QStringLiteral("everything that happens works out for good for the people who love god"),
        QStringLiteral("do not be anxious about tomorrow because tomorrow has its own worries"),
        QStringLiteral("if we admit what we have done wrong he is faithful and will forgive us"),
        QStringLiteral("god has plans to give you a future and a hope and not to harm you"),
        QStringLiteral("in the very beginning god made the heavens and the earth out of nothing"),
    };
}

QStringList speechProbes()
{
    return {
        QStringLiteral("good morning church it is wonderful to see everybody here today"),
        QStringLiteral("before we begin i want to thank the worship team for leading us"),
        QStringLiteral("there are envelopes in the back if you would like to give today"),
        QStringLiteral("we are going to be starting a brand new series next sunday morning"),
        QStringLiteral("the youth group is meeting on wednesday evening in the hall downstairs"),
        QStringLiteral("please remember to sign up for the church picnic before you leave"),
        QStringLiteral("the parking team could use a few more volunteers for the early service"),
        QStringLiteral("we will hand out the new small group booklets at the back table"),
        QStringLiteral("if you are visiting with us for the first time please stop by the desk"),
        QStringLiteral("the building fund update is printed in this morning's bulletin"),
    };
}

// Where should the gates actually sit?
//
// The first thresholds for this path were measured against a four-verse index
// and did not survive contact with 31,102. That is not a mistake anyone should
// have to repeat: the nearest neighbour of ANY sentence rises as the corpus
// grows, so a separation that looks generous among four verses can vanish
// among thirty thousand. This mode prints the two distributions that matter —
// what real paraphrases score, and what ordinary church speech scores — so
// the numbers in AllusionMatcher::Config are read off evidence.
int calibrate(OnnxEmbedder& emb, const QString& indexPath)
{
    AllusionIndex idx;
    QString err;
    if (!idx.load(indexPath, emb.modelId(), &err)) {
        out() << "error: " << err << "\n";
        out().flush();
        return 1;
    }
    out() << "index:  " << indexPath << "  (" << idx.count() << " verses)\n\n";

    const QStringList paraphrases = paraphraseProbes();
    const QStringList speech      = speechProbes();

    auto report = [&](const QString& label, const QStringList& lines) {
        out() << label << "\n";
        float lo = 2.0f, hi = -2.0f;
        for (const QString& s : lines) {
            const auto hits = idx.search(emb.embedOne(s), 8);
            if (hits.isEmpty()) continue;
            const float top = hits.first().score;
            lo = std::min(lo, top);
            hi = std::max(hi, top);

            // How many verses sit within 0.04 of the best — the crowd size
            // the third gate keys off.
            int cluster = 0;
            for (const auto& h : hits)
                if (top - h.score <= 0.04f) ++cluster;

            out() << QStringLiteral("  %1  cluster %2  %3 %4:%5   %6\n")
                         .arg(top, 0, 'f', 3).arg(cluster, 2)
                         .arg(hits.first().book).arg(hits.first().chapter)
                         .arg(hits.first().verse)
                         .arg(s.left(56));
        }
        out() << QStringLiteral("  -> range %1 .. %2\n\n").arg(lo, 0, 'f', 3).arg(hi, 0, 'f', 3);
        return QPair<float, float>(lo, hi);
    };

    const auto p = report(QStringLiteral("PARAPHRASES (should fire)"), paraphrases);
    const auto s = report(QStringLiteral("ORDINARY SPEECH (must not fire)"), speech);

    out() << QStringLiteral("paraphrase floor  %1\nspeech ceiling    %2\nseparation        %3\n")
                 .arg(p.first, 0, 'f', 3).arg(s.second, 0, 'f', 3)
                 .arg(p.first - s.second, 0, 'f', 3);
    if (p.first > s.second) {
        out() << QStringLiteral("suggested minScore ~ %1\n")
                     .arg((p.first + s.second) / 2.0f, 0, 'f', 3);
    } else {
        out() << "the two distributions OVERLAP: no absolute threshold separates them, "
                 "and the cluster rule has to carry the difference.\n";
    }
    out().flush();
    return 0;
}

// What does the operator actually SEE?
//
// --calibrate prints geometry; this prints decisions. It drives the real
// AllusionMatcher, with the real config it ships with, over the real index —
// so the windowing, the per-window content floor and all three gates are the
// ones that will run on stage, not a re-implementation of them that agrees
// with the shipping code only until someone edits one of the two.
//
// Read the output as two columns of one number each: how many paraphrases
// produced at least one suggestion (higher is better) and how many
// announcements produced any at all (must be zero).
int gates(OnnxEmbedder& emb, const QString& indexPath, float minScore, int maxCluster)
{
    AllusionIndex idx;
    QString err;
    if (!idx.load(indexPath, emb.modelId(), &err)) {
        out() << "error: " << err << "\n";
        out().flush();
        return 1;
    }

    AllusionMatcher m;
    m.setIndex(&idx);
    m.setEmbedder([&](const QString& t) { return emb.embedOne(t); });

    // Overrides exist so the operating point can be swept without a rebuild.
    // Sweeping matters more than any single number here: the useful output of
    // this mode is the shape of the recall/false-positive curve, which is what
    // tells you whether a threshold sits on a plateau or on a cliff edge.
    if (minScore > 0.0f || maxCluster > 0) {
        AllusionMatcher::Config cfg = m.config();
        if (minScore > 0.0f)  cfg.minScore   = minScore;
        if (maxCluster > 0) { cfg.maxCluster = maxCluster;
                              cfg.maxEmits   = std::max(cfg.maxEmits, maxCluster); }
        m.setConfig(cfg);
    }

    const auto& c = m.config();
    out() << "index:  " << indexPath << "  (" << idx.count() << " verses)\n";
    out() << QStringLiteral("config: minScore %1  cluster<=%2  window %3  probe %4  "
                            "content>=%5  maxEmits %6\n\n")
                 .arg(c.minScore, 0, 'f', 3).arg(c.maxCluster)
                 .arg(c.clusterWindow, 0, 'f', 3).arg(c.probeDepth)
                 .arg(c.minContentWords).arg(c.maxEmits);

    auto run = [&](const QString& label, const QStringList& lines) {
        out() << label << "\n";
        int fired = 0;
        for (const QString& s : lines) {
            const auto refs = m.match(s, 0);
            if (!refs.isEmpty()) ++fired;

            QStringList names;
            for (const HeardReference& r : refs) names << r.reference;
            out() << QStringLiteral("  %1  %2\n")
                         .arg(refs.isEmpty() ? QStringLiteral("--- silent   ")
                                             : QStringLiteral("--> %1 hit%2 ")
                                                   .arg(refs.size())
                                                   .arg(refs.size() == 1 ? QLatin1String(" ")
                                                                         : QLatin1String("s")),
                              s.left(58));
            if (!refs.isEmpty())
                out() << QStringLiteral("        %1\n").arg(names.join(QStringLiteral(", ")));
        }
        out() << QStringLiteral("  -> %1 of %2 fired\n\n").arg(fired).arg(lines.size());
        return fired;
    };

    const int hits  = run(QStringLiteral("PARAPHRASES (should fire)"), paraphraseProbes());
    const int noise = run(QStringLiteral("ORDINARY SPEECH (must not fire)"), speechProbes());

    out() << QStringLiteral("recall %1/8   false positives %2/10\n").arg(hits).arg(noise);
    if (noise > 0)
        out() << "a false positive here is an announcement in the operator's queue; "
                 "tighten minScore or maxCluster before shipping this config.\n";
    out().flush();
    return 0;
}

}  // namespace

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QCoreApplication::setApplicationName(QStringLiteral("Crater"));

    QString modelPath;
    QString translation = QStringLiteral("KJV");
    QString outPath;
    bool    compare   = false;
    bool    calibrate_ = false;
    bool    gates_     = false;
    float   minScore   = 0.0f;   // 0 = use the shipping default
    int     maxCluster = 0;      // 0 = ditto

    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        const QString& a = args.at(i);
        if (a == QLatin1String("--model") && i + 1 < args.size())            modelPath   = args.at(++i);
        else if (a == QLatin1String("--translation") && i + 1 < args.size()) translation = args.at(++i);
        else if (a == QLatin1String("--out") && i + 1 < args.size())         outPath     = args.at(++i);
        else if (a == QLatin1String("--compare"))                            compare     = true;
        else if (a == QLatin1String("--calibrate"))                          calibrate_  = true;
        else if (a == QLatin1String("--gates"))                              gates_      = true;
        else if (a == QLatin1String("--min-score") && i + 1 < args.size())   minScore    = args.at(++i).toFloat();
        else if (a == QLatin1String("--max-cluster") && i + 1 < args.size()) maxCluster  = args.at(++i).toInt();
    }

    if (modelPath.isEmpty()) {
        out() << "usage: build_allusion_index --model <path.onnx> "
                 "[--translation KJV] [--out <path.crai>]\n"
                 "       [--compare]    which translation embeds closest to spoken paraphrase\n"
                 "       [--calibrate]  raw score distributions, paraphrase vs ordinary speech\n"
                 "       [--gates]      what the shipping matcher actually emits for each\n"
                 "                      sweep it with --min-score <f> --max-cluster <n>\n";
        out().flush();
        return 2;
    }

    OnnxEmbedder emb;
    QString err;
    if (!emb.load(modelPath, &err)) {
        out() << "error: " << err << "\n";
        out().flush();
        return 1;
    }
    out() << "model:  " << QFileInfo(modelPath).fileName()
          << "  (" << emb.modelId() << ", " << emb.dimensions() << "d)\n";

    BibleService bible;
    if (bible.translations().isEmpty()) {
        out() << "error: no translations installed at " << db::DbPaths::biblesDbPath() << "\n";
        out().flush();
        return 1;
    }

    if (compare) return compareTranslations(bible, emb);

    if (calibrate_ || gates_) {
        QString p = outPath;
        if (p.isEmpty())
            p = QDir(db::DbPaths::dataDir())
                    .filePath(QStringLiteral("models/allusion-%1.crai").arg(translation));
        return gates_ ? gates(emb, p, minScore, maxCluster) : calibrate(emb, p);
    }

    const QList<Verse> verses = bible.allVerses(translation);
    if (verses.isEmpty()) {
        out() << "error: translation " << translation << " has no verses\n";
        out().flush();
        return 1;
    }
    out() << "corpus: " << verses.size() << " verses of " << translation << "\n";
    out().flush();

    QList<AllusionIndex::Entry> entries;
    entries.reserve(verses.size());

    QElapsedTimer clock;
    clock.start();

    for (int i = 0; i < verses.size(); ++i) {
        const Verse& v = verses.at(i);
        AllusionIndex::Entry e;
        e.book    = v.book;
        e.chapter = v.chapter;
        e.verse   = v.verse;
        e.vector  = emb.embedOne(v.text);
        if (e.vector.isEmpty()) {
            out() << "\nerror: failed to embed " << v.reference() << "\n";
            out().flush();
            return 1;
        }
        entries.append(std::move(e));

        if ((i + 1) % 500 == 0 || i + 1 == verses.size()) {
            const double done    = double(i + 1) / double(verses.size());
            const double elapsed = double(clock.elapsed()) / 1000.0;
            out() << QStringLiteral("\r  %1 / %2  (%3%)  %4s elapsed, ~%5s left        ")
                         .arg(i + 1).arg(verses.size())
                         .arg(done * 100.0, 0, 'f', 1)
                         .arg(elapsed, 0, 'f', 0)
                         .arg(done > 0 ? (elapsed / done - elapsed) : 0.0, 0, 'f', 0);
            out().flush();
        }
    }
    out() << "\n";

    AllusionIndex idx;
    if (!idx.build(entries, emb.modelId(), &err)) {
        out() << "error: " << err << "\n";
        out().flush();
        return 1;
    }

    if (outPath.isEmpty()) {
        outPath = QDir(db::DbPaths::dataDir())
                      .filePath(QStringLiteral("models/allusion-%1.crai").arg(translation));
    }
    QDir().mkpath(QFileInfo(outPath).absolutePath());

    if (!idx.save(outPath, &err)) {
        out() << "error: " << err << "\n";
        out().flush();
        return 1;
    }

    out() << "wrote " << outPath << "  ("
          << QStringLiteral("%1 MB, %2 verses, %3d")
                 .arg(double(QFileInfo(outPath).size()) / (1024.0 * 1024.0), 0, 'f', 1)
                 .arg(idx.count())
                 .arg(idx.dimensions())
          << ")\n";
    out().flush();
    return 0;
}
