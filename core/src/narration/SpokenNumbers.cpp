#include "narration/SpokenNumbers.h"

#include <QHash>
#include <QRegularExpression>

namespace crater::narration {
namespace {

// Cardinals plus the tens scaffolding. "hundred" is handled separately in the
// composition loop because it multiplies rather than adds.
const QHash<QString, int>& cardinals()
{
    static const QHash<QString, int> t = {
        { QStringLiteral("zero"),      0 }, { QStringLiteral("one"),        1 },
        { QStringLiteral("two"),       2 }, { QStringLiteral("three"),      3 },
        { QStringLiteral("four"),      4 }, { QStringLiteral("five"),       5 },
        { QStringLiteral("six"),       6 }, { QStringLiteral("seven"),      7 },
        { QStringLiteral("eight"),     8 }, { QStringLiteral("nine"),       9 },
        { QStringLiteral("ten"),      10 }, { QStringLiteral("eleven"),    11 },
        { QStringLiteral("twelve"),   12 }, { QStringLiteral("thirteen"),  13 },
        { QStringLiteral("fourteen"), 14 }, { QStringLiteral("fifteen"),   15 },
        { QStringLiteral("sixteen"),  16 }, { QStringLiteral("seventeen"), 17 },
        { QStringLiteral("eighteen"), 18 }, { QStringLiteral("nineteen"),  19 },
        { QStringLiteral("twenty"),   20 }, { QStringLiteral("thirty"),    30 },
        { QStringLiteral("forty"),    40 }, { QStringLiteral("fifty"),     50 },
        { QStringLiteral("sixty"),    60 }, { QStringLiteral("seventy"),   70 },
        { QStringLiteral("eighty"),   80 }, { QStringLiteral("ninety"),    90 },
    };
    return t;
}

// Ordinals are a separate table because consuming one terminates the phrase:
// "twenty third" is 23, but "twenty third fourth" is not a number. Kept here
// rather than folded into cardinals so that rule has somewhere to live.
//
// These carry real false-positive risk on their own ("first of all", "the
// second thing I want to say"), which is why parseNumberPhrase is only ever
// called from positions the detector has already gated on context.
const QHash<QString, int>& ordinals()
{
    static const QHash<QString, int> t = {
        { QStringLiteral("first"),       1 }, { QStringLiteral("1st"),        1 },
        { QStringLiteral("second"),      2 }, { QStringLiteral("2nd"),        2 },
        { QStringLiteral("third"),       3 }, { QStringLiteral("3rd"),        3 },
        { QStringLiteral("fourth"),      4 }, { QStringLiteral("4th"),        4 },
        { QStringLiteral("fifth"),       5 }, { QStringLiteral("5th"),        5 },
        { QStringLiteral("sixth"),       6 }, { QStringLiteral("6th"),        6 },
        { QStringLiteral("seventh"),     7 }, { QStringLiteral("7th"),        7 },
        { QStringLiteral("eighth"),      8 }, { QStringLiteral("8th"),        8 },
        { QStringLiteral("ninth"),       9 }, { QStringLiteral("9th"),        9 },
        { QStringLiteral("tenth"),      10 }, { QStringLiteral("10th"),      10 },
        { QStringLiteral("eleventh"),   11 }, { QStringLiteral("twelfth"),   12 },
        { QStringLiteral("thirteenth"), 13 }, { QStringLiteral("fourteenth"),14 },
        { QStringLiteral("fifteenth"),  15 }, { QStringLiteral("sixteenth"), 16 },
        { QStringLiteral("seventeenth"),17 }, { QStringLiteral("eighteenth"),18 },
        { QStringLiteral("nineteenth"), 19 }, { QStringLiteral("twentieth"), 20 },
        { QStringLiteral("thirtieth"),  30 }, { QStringLiteral("fortieth"),  40 },
        { QStringLiteral("fiftieth"),   50 }, { QStringLiteral("sixtieth"),  60 },
    };
    return t;
}

std::optional<int> wordValue(const QString& w, bool& isOrdinal)
{
    isOrdinal = false;
    if (const auto c = cardinals().constFind(w); c != cardinals().constEnd())
        return *c;
    if (const auto o = ordinals().constFind(w); o != ordinals().constEnd()) {
        isOrdinal = true;
        return *o;
    }
    return std::nullopt;
}

// Bare digit run, 1..3 chars. Chapters top out at 150 and verses at 176, so a
// longer run is a year, a street number, or a hallucinated timestamp — not
// scripture coordinates.
bool isDigitRun(const QString& w)
{
    static const QRegularExpression rx(QStringLiteral("^\\d{1,3}$"));
    return rx.match(w).hasMatch();
}

// "23rd" / "1st" — whisper emits these when it renders an ordinal as digits.
std::optional<int> digitOrdinal(const QString& w)
{
    static const QRegularExpression rx(QStringLiteral("^(\\d{1,3})(st|nd|rd|th)$"));
    const auto m = rx.match(w);
    if (!m.hasMatch()) return std::nullopt;
    return m.captured(1).toInt();
}

}  // namespace

QStringList tokenize(const QString& utterance)
{
    // Everything that isn't a letter or a digit becomes a separator. That
    // folds "3:16" into two tokens (matching the spoken "three sixteen" shape)
    // and "twenty-two" into the two the tens+unit rule wants, and it disposes
    // of whatever punctuation and dash variants the recognizer emitted without
    // us enumerating them.
    static const QRegularExpression nonWord(QStringLiteral("[^a-z0-9]+"));
    return utterance.toLower().split(nonWord, Qt::SkipEmptyParts);
}

bool isNumericToken(QStringView word)
{
    const QString w = word.toString();
    return isDigitRun(w) || digitOrdinal(w).has_value()
           || cardinals().contains(w) || ordinals().contains(w)
           || w == QStringLiteral("hundred");
}

std::optional<NumberPhrase> parseNumberPhrase(const QStringList& words, int i)
{
    if (i < 0 || i >= words.size()) return std::nullopt;

    // Digit runs consume exactly one token and never compose with anything.
    // "3 16" has to stay two numbers or John 3:16 parses as a single value.
    if (isDigitRun(words[i]))
        return NumberPhrase{ words[i].toInt(), i, i + 1, false };
    if (const auto d = digitOrdinal(words[i]))
        return NumberPhrase{ *d, i, i + 1, true };

    int  cur    = 0;
    int  n      = 0;
    bool any    = false;
    bool closed = false;   // an ordinal was consumed, so the phrase is finished

    while (i + n < words.size() && !closed) {
        const QString& w = words[i + n];

        if (w == QStringLiteral("hundred")) {
            // Needs a preceding unit, and can't apply twice.
            if (!any || cur == 0 || cur >= 100) break;
            cur *= 100;
            ++n;
            continue;
        }

        if (w == QStringLiteral("and")) {
            // Only the connective inside "one hundred and nineteen". Anywhere
            // else, "and" is joining two separate references and the detector
            // needs to see it.
            if (!any || cur < 100 || cur % 100 != 0) break;
            if (i + n + 1 >= words.size() || !isNumericToken(words[i + n + 1])) break;
            ++n;
            continue;
        }

        bool       isOrd = false;
        const auto v     = wordValue(w, isOrd);
        if (!v) break;

        if (!any) {
            cur    = *v;
            any    = true;
            closed = isOrd;
            ++n;
            continue;
        }

        // Hundreds absorb a sub-100 remainder: "one hundred nineteen" → 119.
        if (cur >= 100 && cur % 100 == 0 && *v < 100) {
            cur += *v;
            closed = isOrd;
            ++n;
            continue;
        }
        // Tens absorb a unit: "twenty two" → 22.
        if (cur >= 20 && cur <= 90 && cur % 10 == 0 && *v >= 1 && *v <= 9) {
            cur += *v;
            closed = isOrd;
            ++n;
            continue;
        }

        // No composition rule applies, so this is the next number, not part of
        // this one. "three sixteen" lands here and stops at 3.
        break;
    }

    if (!any) return std::nullopt;
    return NumberPhrase{ cur, i, i + n, closed };
}

std::optional<int> parseOrdinalPrefix(QStringView word)
{
    const QString w = word.toString();
    if (const auto o = ordinals().constFind(w); o != ordinals().constEnd())
        return *o <= 3 ? std::optional<int>(*o) : std::nullopt;
    if (const auto c = cardinals().constFind(w); c != cardinals().constEnd())
        return *c >= 1 && *c <= 3 ? std::optional<int>(*c) : std::nullopt;
    if (isDigitRun(w)) {
        const int v = w.toInt();
        return v >= 1 && v <= 3 ? std::optional<int>(v) : std::nullopt;
    }
    return std::nullopt;
}

}  // namespace crater::narration
