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
#include "narration/OnnxEmbedder.h"

using namespace crater;
using narration::AllusionIndex;
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

}  // namespace

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QCoreApplication::setApplicationName(QStringLiteral("Crater"));

    QString modelPath;
    QString translation = QStringLiteral("KJV");
    QString outPath;
    bool    compare = false;

    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        const QString& a = args.at(i);
        if (a == QLatin1String("--model") && i + 1 < args.size())            modelPath   = args.at(++i);
        else if (a == QLatin1String("--translation") && i + 1 < args.size()) translation = args.at(++i);
        else if (a == QLatin1String("--out") && i + 1 < args.size())         outPath     = args.at(++i);
        else if (a == QLatin1String("--compare"))                            compare     = true;
    }

    if (modelPath.isEmpty()) {
        out() << "usage: build_allusion_index --model <path.onnx> "
                 "[--translation KJV] [--out <path.crai>] [--compare]\n";
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
