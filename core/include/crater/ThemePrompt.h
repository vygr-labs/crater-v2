#pragma once

#include <QString>
#include <QVariantMap>

namespace crater::prompt {

// Builds the authoring brief a user copies out of the theme editor and pastes
// into a general-purpose AI ("design me a theme"). The AI's reply comes back
// through ThemeService::parseThemeJsonText and lands in the editor.
//
// ── Why the whole contract is inlined ──────────────────────────────────
// qt/docs/theme-schema.md is the authoring contract, but it lives in this
// repo and the AI on the other end has never seen it. Anything the validator
// requires and this prompt omits comes back as a rejected paste that the user
// cannot diagnose, because the error names a field the AI was never told
// about. So the prompt restates the contract in full rather than referring to
// it, and the checklist at the end mirrors the validator's actual rules.
//
// That makes this file a SECOND statement of the schema, which is exactly the
// kind of duplication the rest of the theming code goes out of its way to
// avoid (see the "derived, not declared" note in ThemeTokens.h). It is
// accepted here for one reason: the consumer is outside the process. There is
// no way to hand a remote model a live reference, and a prompt that says "see
// the docs" produces invented fields. The mitigation is that both statements
// are checked by the same validator the moment the user pastes, so drift
// surfaces as a failed paste during authoring rather than as a broken theme.
//
// Kept out of the UI layer per the thin-executable rule: this is data, and the
// app binary should only be moving it around.

// The full brief for a theme of `kind` ("song", "scripture" or
// "presentation").
//
// `brief` is the user's own description of what they want, pasted in
// verbatim. Empty is a supported and deliberate case: the prompt then tells
// the model to use its own judgement, which is the "surprise me" path.
//
// `startFrom` is an optional tokens map (v2 or v3). When non-empty it is
// appended as the current design with an instruction to evolve it rather than
// start over, which is what makes the feature usable as a redesign tool and
// not only as a generator.
//
// ASCII only, by construction. The result is pasted into a browser text box,
// and smart quotes / em-dashes both read as machine-written and have a habit
// of arriving mangled through clipboard round trips.
QString designPrompt(const QString&     kind,
                     const QString&     brief     = QString(),
                     const QVariantMap& startFrom = QVariantMap());

}  // namespace crater::prompt
