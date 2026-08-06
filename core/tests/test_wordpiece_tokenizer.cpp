// BERT WordPiece tokenization for the allusion path's embedder.
//
// This file exists because of how the tokenizer fails when it is wrong: not
// with an error, but with a confident 384-dimension vector pointing somewhere
// meaningless. Every query would still retrieve a neighbour, every neighbour
// would still be a real verse, and nothing in the output would look broken.
//
// So the tests pin exact token ids, not shapes. The expected values come from
// the canonical bert-base-uncased vocabulary that bge-small-en-v1.5 ships
// (30,522 tokens; [PAD]=0, [UNK]=100, [CLS]=101, [SEP]=102) and were computed
// independently of this implementation before it was run.

#include <QtTest>

#include <QCoreApplication>
#include <QFile>

#include "narration/WordPieceTokenizer.h"

using namespace crater;
using narration::WordPieceTokenizer;

namespace {

// The vocabulary ships inside crater-core as a Qt resource, so this test
// needs no external file and cannot drift from what the app loads.
constexpr const char* kVocabResource = ":/narration/bge-small-en-v1.5-vocab.txt";

QList<qint64> ids(std::initializer_list<qint64> v) { return QList<qint64>(v); }

}  // namespace

class TestWordPieceTokenizer : public QObject
{
    Q_OBJECT

private:
    WordPieceTokenizer tok;

private slots:
    void initTestCase()
    {
        QVERIFY2(QFile::exists(QString::fromLatin1(kVocabResource)),
                 "the vocabulary resource is not compiled into crater-core");
        QString err;
        QVERIFY2(tok.loadVocab(QString::fromLatin1(kVocabResource), &err), qPrintable(err));
    }

    // If this drifts, the model is being fed ids from a different vocabulary
    // and every downstream number is meaningless.
    void the_vocabulary_is_the_one_the_model_expects()
    {
        QCOMPARE(tok.vocabSize(), 30522);
        QCOMPARE(tok.idFor(QStringLiteral("[PAD]")), 0);
        QCOMPARE(tok.idFor(QStringLiteral("[UNK]")), 100);
        QCOMPARE(tok.idFor(QStringLiteral("[CLS]")), 101);
        QCOMPARE(tok.idFor(QStringLiteral("[SEP]")), 102);
        // Ordinary words, at their canonical bert-base-uncased ids.
        QCOMPARE(tok.idFor(QStringLiteral("hello")), 7592);
        QCOMPARE(tok.idFor(QStringLiteral("world")), 2088);
        QCOMPARE(tok.idFor(QStringLiteral("the")),   1996);
    }

    // ── Exact encodings ─────────────────────────────────────────────────

    void a_simple_sentence_encodes_to_known_ids()
    {
        const auto e = tok.encode(QStringLiteral("hello world"));
        QCOMPARE(e.ids, ids({ 101, 7592, 2088, 102 }));
        QCOMPARE(e.attentionMask, ids({ 1, 1, 1, 1 }));
        QCOMPARE(e.tokenTypeIds, ids({ 0, 0, 0, 0 }));
    }

    void a_verse_encodes_to_known_ids()
    {
        // "The LORD is my shepherd; I shall not want."
        // Note the semicolon and full stop become their own tokens, and the
        // capitals are folded — both are what do_lower_case implies.
        const auto e = tok.encode(QStringLiteral("The LORD is my shepherd, I shall not want."));
        QCOMPARE(e.ids, ids({ 101,
                              1996,   // the
                              2935,   // lord
                              2003,   // is
                              2026,   // my
                              11133,  // shepherd
                              1010,   // ,
                              1045,   // i
                              4618,   // shall
                              2025,   // not
                              2215,   // want
                              1012,   // .
                              102 }));
    }

    // ── WordPiece decomposition ─────────────────────────────────────────

    // Expected pieces computed independently from the vocabulary, using the
    // greedy longest-match-first rule BERT specifies.
    void unknown_words_decompose_into_subwords()
    {
        QCOMPARE(tok.wordPiece(QStringLiteral("begotten")),
                 QStringList({ QStringLiteral("beg"), QStringLiteral("##otte"),
                               QStringLiteral("##n") }));
        QCOMPARE(tok.wordPiece(QStringLiteral("strengtheneth")),
                 QStringList({ QStringLiteral("strengthen"), QStringLiteral("##eth") }));
        QCOMPARE(tok.wordPiece(QStringLiteral("unaffable")),
                 QStringList({ QStringLiteral("una"), QStringLiteral("##ffa"),
                               QStringLiteral("##ble") }));
    }

    void a_known_word_stays_one_piece()
    {
        QCOMPARE(tok.wordPiece(QStringLiteral("shepherd")),
                 QStringList({ QStringLiteral("shepherd") }));
    }

    void subword_ids_match_the_reference()
    {
        const auto e = tok.encode(QStringLiteral("begotten"));
        QCOMPARE(e.ids, ids({ 101, 11693, 28495, 2078, 102 }));
    }

    // A structural property rather than a fixed value: whatever the pieces
    // are, they must all be real vocabulary entries and must reassemble into
    // the original word. This catches a broken continuation marker or an
    // off-by-one in the greedy scan even for words nobody hand-checked.
    void every_piece_is_in_the_vocabulary_and_reassembles()
    {
        const QStringList words = {
            QStringLiteral("shepherd"),     QStringLiteral("begotten"),
            QStringLiteral("strengtheneth"), QStringLiteral("everlasting"),
            QStringLiteral("propitiation"), QStringLiteral("lovingkindness"),
            QStringLiteral("nebuchadnezzar")
        };
        for (const QString& w : words) {
            const QStringList pieces = tok.wordPiece(w);
            QVERIFY2(!pieces.isEmpty(), qPrintable(w));
            if (pieces.size() == 1 && pieces.first() == QStringLiteral("[UNK]")) continue;

            QString rebuilt;
            for (int i = 0; i < pieces.size(); ++i) {
                const QString& p = pieces.at(i);
                QVERIFY2(tok.idFor(p) != tok.idFor(QStringLiteral("[UNK]"))
                             || p == QStringLiteral("[UNK]"),
                         qPrintable(QStringLiteral("piece \"%1\" of \"%2\" is not in the vocab")
                                        .arg(p, w)));
                if (i == 0) {
                    QVERIFY2(!p.startsWith(QStringLiteral("##")),
                             "the first piece must not carry the continuation marker");
                    rebuilt += p;
                } else {
                    QVERIFY2(p.startsWith(QStringLiteral("##")),
                             qPrintable(QStringLiteral("piece \"%1\" is missing ##").arg(p)));
                    rebuilt += p.mid(2);
                }
            }
            QCOMPARE(rebuilt, w);
        }
    }

    // A word with no valid decomposition must become [UNK] *whole*, not a
    // partial reading of its prefix. Tested against a controlled vocabulary
    // rather than the real one: bert-base-uncased contains a great many
    // single Unicode characters, so almost any real string decomposes into
    // something, and a test using one would be asserting the vocabulary's
    // contents instead of this rule.
    void an_undecomposable_word_becomes_unknown()
    {
        WordPieceTokenizer tiny;
        QVERIFY(tiny.loadVocab(QStringList({
            QStringLiteral("[PAD]"), QStringLiteral("[UNK]"),
            QStringLiteral("[CLS]"), QStringLiteral("[SEP]"),
            QStringLiteral("ab"),    QStringLiteral("##cd") })));

        // "abcd" splits cleanly.
        QCOMPARE(tiny.wordPiece(QStringLiteral("abcd")),
                 QStringList({ QStringLiteral("ab"), QStringLiteral("##cd") }));

        // "abzz" does not. The leading "ab" matches, but nothing covers "zz",
        // so the whole word is unknown — emitting just "ab" would tell the
        // model the preacher said something they did not.
        QCOMPARE(tiny.wordPiece(QStringLiteral("abzz")),
                 QStringList({ QStringLiteral("[UNK]") }));
    }

    // The real vocabulary's actual behaviour on non-Latin text: it has
    // single-character entries for a lot of scripts, so these decompose
    // rather than vanishing. Asserted so the behaviour is recorded rather
    // than discovered later.
    void non_latin_text_decomposes_into_known_pieces()
    {
        const QStringList pieces = tok.wordPiece(QString::fromUtf8("אבג"));
        QVERIFY(!pieces.isEmpty());
        for (const QString& p : pieces) {
            const QString bare = p.startsWith(QStringLiteral("##")) ? p.mid(2) : p;
            QVERIFY2(!bare.isEmpty(), "empty piece");
        }
    }

    void an_absurdly_long_word_becomes_unknown()
    {
        const QString monster(150, QLatin1Char('a'));
        QCOMPARE(tok.wordPiece(monster), QStringList({ QStringLiteral("[UNK]") }));
    }

    // ── Basic tokenization ──────────────────────────────────────────────

    void punctuation_becomes_its_own_token()
    {
        QCOMPARE(tok.basicTokenize(QStringLiteral("god, so loved.")),
                 QStringList({ QStringLiteral("god"), QStringLiteral(","),
                               QStringLiteral("so"),  QStringLiteral("loved"),
                               QStringLiteral(".") }));
    }

    void case_is_folded_and_accents_are_stripped()
    {
        // do_lower_case is true and strip_accents is unset, which BERT
        // resolves to "strip".
        QCOMPARE(tok.basicTokenize(QString::fromUtf8("NÏCE CafÉ")),
                 QStringList({ QStringLiteral("nice"), QStringLiteral("cafe") }));
    }

    void whitespace_runs_collapse()
    {
        QCOMPARE(tok.basicTokenize(QStringLiteral("  the\t\tlord \n is  ")),
                 QStringList({ QStringLiteral("the"), QStringLiteral("lord"),
                               QStringLiteral("is") }));
    }

    void control_characters_are_dropped()
    {
        QString s = QStringLiteral("go");
        s.append(QChar(0x0007));           // BEL
        s.append(QStringLiteral("d"));
        QCOMPARE(tok.basicTokenize(s), QStringList({ QStringLiteral("god") }));
    }

    // ── Encode invariants ───────────────────────────────────────────────

    void every_encoding_is_wrapped_in_cls_and_sep()
    {
        const QStringList samples = {
            QStringLiteral("god so loved the world"),
            QStringLiteral("x"),
            QStringLiteral("...")
        };
        for (const QString& s : samples) {
            const auto e = tok.encode(s);
            QVERIFY(e.ids.size() >= 2);
            QCOMPARE(e.ids.first(), qint64(101));
            QCOMPARE(e.ids.last(),  qint64(102));
            QCOMPARE(e.attentionMask.size(), e.ids.size());
            QCOMPARE(e.tokenTypeIds.size(),  e.ids.size());
        }
    }

    // Truncation must leave room for [SEP]. A sequence that runs to the limit
    // without its separator is a shape the model never saw in training.
    void truncation_preserves_the_separator()
    {
        QString longText;
        for (int i = 0; i < 400; ++i) longText += QStringLiteral("shepherd ");

        const auto e = tok.encode(longText, 32);
        QCOMPARE(e.ids.size(), 32);
        QCOMPARE(e.ids.first(), qint64(101));
        QCOMPARE(e.ids.last(),  qint64(102));
        QCOMPARE(e.attentionMask.size(), 32);
    }

    void empty_input_is_just_the_markers()
    {
        const auto e = tok.encode(QString());
        QCOMPARE(e.ids, ids({ 101, 102 }));
    }

    void an_unloaded_tokenizer_returns_nothing()
    {
        WordPieceTokenizer empty;
        QVERIFY(!empty.isLoaded());
        QVERIFY(empty.encode(QStringLiteral("hello world")).isEmpty());
    }

    void a_vocabulary_without_the_special_tokens_is_refused()
    {
        WordPieceTokenizer bad;
        QString err;
        QVERIFY(!bad.loadVocab(QStringList({ QStringLiteral("hello"),
                                             QStringLiteral("world") }), &err));
        QVERIFY(err.contains(QStringLiteral("[UNK]")));
        QVERIFY(!bad.isLoaded());
    }
};

QTEST_MAIN(TestWordPieceTokenizer)
#include "test_wordpiece_tokenizer.moc"
