#pragma once

#include <QString>
#include <QStringList>
#include <QStringView>

#include <optional>

namespace crater::narration {

// Spoken-number normalization for the citation detector.
// See docs/narration.md §4.1.
//
// Whisper emits numbers inconsistently — digits ("John 3 16"), words
// ("chapter thirteen"), and mixed forms inside a single utterance. Everything
// normalizes through here.

// One number phrase lifted out of the word stream.
struct NumberPhrase
{
    int  value    = 0;
    int  startIdx = 0;   // index into the word list
    int  endIdx   = 0;   // one past the last word consumed
    // True when the phrase ended on an ordinal ("twenty third"). The detector
    // uses this to recognize the number-before-book form — "the twenty-third
    // psalm" — which a cardinal must not trigger.
    bool ordinal  = false;
};

// Split an utterance into comparable lowercase word tokens.
//
// Colons and hyphens become separators, which is load-bearing rather than
// cosmetic: "3:16" collapses onto the same "N M" adjacency rule the spoken
// form "three sixteen" produces, and "twenty-two" splits into the two tokens
// the tens+unit composition rule expects.
QStringList tokenize(const QString& utterance);

// Parse exactly ONE number phrase beginning at `words[i]`. Returns nullopt
// when words[i] does not start a number.
//
// The rule that matters is adjacency (docs/narration.md §4.1): this consumes
// only as many tokens as compose a single English number, so "twenty two"
// yields 22 while "three sixteen" yields 3 and stops. That leaves the second
// number for the caller to read as a verse, which is what makes the most
// common spoken form of the most commonly quoted verse in the Bible parse
// correctly. It falls out of number grammar rather than a special case.
std::optional<NumberPhrase> parseNumberPhrase(const QStringList& words, int i);

// Leading ordinal for a digit-prefixed book: "first" / "1st" / "one" / "1"
// all yield 1. Speech is unpredictable here and all forms are common.
std::optional<int> parseOrdinalPrefix(QStringView word);

// True when the token is any recognized numeric word or a digit run. Used by
// the detector to decide whether a trailing "and" is joining a number.
bool isNumericToken(QStringView word);

}  // namespace crater::narration
