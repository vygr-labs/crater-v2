#include "narration/WordPieceTokenizer.h"

#include <QFile>
#include <QTextStream>

namespace crater::narration {

namespace {

// BERT's `_is_punctuation`: the ASCII punctuation blocks are treated as
// punctuation even where Unicode disagrees (it classes some of them as
// symbols), plus anything Unicode itself calls punctuation.
bool isPunctuation(QChar c)
{
    const ushort u = c.unicode();
    if ((u >= 33 && u <= 47) || (u >= 58 && u <= 64)
        || (u >= 91 && u <= 96) || (u >= 123 && u <= 126))
        return true;

    switch (c.category()) {
    case QChar::Punctuation_Connector:
    case QChar::Punctuation_Dash:
    case QChar::Punctuation_Open:
    case QChar::Punctuation_Close:
    case QChar::Punctuation_InitialQuote:
    case QChar::Punctuation_FinalQuote:
    case QChar::Punctuation_Other:
        return true;
    default:
        return false;
    }
}

bool isControlChar(QChar c)
{
    // Tab, newline and carriage return are whitespace to BERT, not control
    // characters, and are handled by the whitespace pass instead.
    if (c == QLatin1Char('\t') || c == QLatin1Char('\n') || c == QLatin1Char('\r'))
        return false;

    switch (c.category()) {
    case QChar::Other_Control:
    case QChar::Other_Format:
    case QChar::Other_Surrogate:
    case QChar::Other_PrivateUse:
    case QChar::Other_NotAssigned:
        return true;
    default:
        return false;
    }
}

bool isWhitespace(QChar c)
{
    if (c == QLatin1Char(' ') || c == QLatin1Char('\t')
        || c == QLatin1Char('\n') || c == QLatin1Char('\r'))
        return true;
    return c.category() == QChar::Separator_Space;
}

// The CJK blocks BERT surrounds with spaces so every ideograph becomes its
// own token. Not needed for an English-only Bible index, but leaving it out
// would make this tokenizer quietly disagree with the reference one, and a
// tokenizer that is right except sometimes is worse than one that is simply
// right.
bool isCjk(uint cp)
{
    return (cp >= 0x4E00  && cp <= 0x9FFF)
        || (cp >= 0x3400  && cp <= 0x4DBF)
        || (cp >= 0x20000 && cp <= 0x2A6DF)
        || (cp >= 0x2A700 && cp <= 0x2B73F)
        || (cp >= 0x2B740 && cp <= 0x2B81F)
        || (cp >= 0x2B820 && cp <= 0x2CEAF)
        || (cp >= 0xF900  && cp <= 0xFAFF)
        || (cp >= 0x2F800 && cp <= 0x2FA1F);
}

// Lowercase, then decompose and drop combining marks. BERT ties accent
// stripping to do_lower_case, and bge-small sets do_lower_case true with
// strip_accents unset, which resolves to "strip".
QString stripAccentsLower(const QString& s)
{
    const QString decomposed = s.toLower().normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(decomposed.size());
    for (const QChar c : decomposed) {
        if (c.category() == QChar::Mark_NonSpacing) continue;
        out.append(c);
    }
    return out;
}

constexpr int kMaxCharsPerWord = 100;

}  // namespace

bool WordPieceTokenizer::loadVocab(const QString& path, QString* error)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        if (error) *error = QStringLiteral("Cannot read vocabulary %1: %2")
                                .arg(path, f.errorString());
        return false;
    }

    QStringList tokens;
    tokens.reserve(32000);
    QTextStream in(&f);
    in.setEncoding(QStringConverter::Utf8);
    while (!in.atEnd())
        tokens.append(in.readLine());

    // vocab.txt ends with a newline, which yields one trailing empty line.
    while (!tokens.isEmpty() && tokens.last().isEmpty())
        tokens.removeLast();

    return loadVocab(tokens, error);
}

bool WordPieceTokenizer::loadVocab(const QStringList& tokens, QString* error)
{
    m_vocab.clear();
    m_unk = m_cls = m_sep = m_pad = -1;

    if (tokens.isEmpty()) {
        if (error) *error = QStringLiteral("Vocabulary is empty.");
        return false;
    }

    m_vocab.reserve(tokens.size());
    for (int i = 0; i < tokens.size(); ++i) {
        // First occurrence wins: an id is a line number, so a duplicated
        // token must not silently re-point to the later line.
        if (!m_vocab.contains(tokens.at(i)))
            m_vocab.insert(tokens.at(i), i);
    }

    m_unk = m_vocab.value(QStringLiteral("[UNK]"), -1);
    m_cls = m_vocab.value(QStringLiteral("[CLS]"), -1);
    m_sep = m_vocab.value(QStringLiteral("[SEP]"), -1);
    m_pad = m_vocab.value(QStringLiteral("[PAD]"), -1);

    if (m_unk < 0 || m_cls < 0 || m_sep < 0) {
        if (error) *error = QStringLiteral(
            "Vocabulary is missing [UNK], [CLS] or [SEP]; this does not look like "
            "a BERT vocab.txt.");
        m_vocab.clear();
        return false;
    }
    return true;
}

int WordPieceTokenizer::idFor(const QString& token) const
{
    return m_vocab.value(token, m_unk);
}

QStringList WordPieceTokenizer::basicTokenize(const QString& text) const
{
    // Pass 1: strip control characters, normalize whitespace, and isolate
    // CJK ideographs.
    QString cleaned;
    cleaned.reserve(text.size() + 16);
    for (int i = 0; i < text.size(); ++i) {
        const QChar c = text.at(i);
        if (c == QChar(0) || c == QChar(0xFFFD) || isControlChar(c)) continue;
        if (isWhitespace(c)) { cleaned.append(QLatin1Char(' ')); continue; }

        uint cp = c.unicode();
        if (c.isHighSurrogate() && i + 1 < text.size() && text.at(i + 1).isLowSurrogate())
            cp = QChar::surrogateToUcs4(c, text.at(i + 1));

        if (isCjk(cp)) {
            cleaned.append(QLatin1Char(' '));
            cleaned.append(c);
            if (cp > 0xFFFF && i + 1 < text.size()) cleaned.append(text.at(++i));
            cleaned.append(QLatin1Char(' '));
            continue;
        }
        cleaned.append(c);
    }

    // Pass 2: split on whitespace, lowercase + strip accents, then split each
    // piece on punctuation, keeping the punctuation as its own token.
    QStringList out;
    const QStringList rough = cleaned.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (const QString& piece : rough) {
        const QString norm = stripAccentsLower(piece);
        QString current;
        for (const QChar c : norm) {
            if (isPunctuation(c)) {
                if (!current.isEmpty()) { out.append(current); current.clear(); }
                out.append(QString(c));
            } else {
                current.append(c);
            }
        }
        if (!current.isEmpty()) out.append(current);
    }
    return out;
}

QStringList WordPieceTokenizer::wordPiece(const QString& word) const
{
    QStringList out;
    if (word.isEmpty()) return out;

    if (word.size() > kMaxCharsPerWord) {
        out.append(QStringLiteral("[UNK]"));
        return out;
    }

    // Greedy longest-match-first. Every piece after the first carries the
    // "##" continuation marker; if any position fails to match, the WHOLE
    // word becomes [UNK] rather than a partial decomposition.
    int start = 0;
    QStringList pieces;
    while (start < word.size()) {
        int     end = int(word.size());
        QString found;
        while (start < end) {
            QString sub = word.mid(start, end - start);
            if (start > 0) sub.prepend(QStringLiteral("##"));
            if (m_vocab.contains(sub)) { found = sub; break; }
            --end;
        }
        if (found.isEmpty()) return QStringList{ QStringLiteral("[UNK]") };
        pieces.append(found);
        start = end;
    }
    return pieces;
}

WordPieceTokenizer::Encoded WordPieceTokenizer::encode(const QString& text, int maxLen) const
{
    Encoded enc;
    if (!isLoaded() || maxLen < 2) return enc;

    // Two slots reserved for [CLS] and [SEP]: truncation has to leave room
    // for the separator, or the model sees a sequence it was never trained on.
    const int budget = maxLen - 2;

    QList<qint64> ids;
    ids.reserve(maxLen);
    ids.append(m_cls);

    int used = 0;
    const QStringList words = basicTokenize(text);
    for (const QString& w : words) {
        if (used >= budget) break;
        const QStringList pieces = wordPiece(w);
        for (const QString& p : pieces) {
            if (used >= budget) break;
            ids.append(idFor(p));
            ++used;
        }
    }

    ids.append(m_sep);

    enc.ids = ids;
    // No padding: we embed one sentence at a time, so the batch dimension is
    // 1 and there is nothing to pad to. Every position is real, which makes
    // the mask all ones — kept explicit because the graph requires the input
    // and a silently-wrong mask is invisible.
    enc.attentionMask.reserve(ids.size());
    enc.tokenTypeIds.reserve(ids.size());
    for (int i = 0; i < ids.size(); ++i) {
        enc.attentionMask.append(1);
        enc.tokenTypeIds.append(0);   // single segment
    }
    return enc;
}

}  // namespace crater::narration
