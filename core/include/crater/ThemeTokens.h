#pragma once

#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

namespace crater::tokens {

// Pure functions over a theme's token map — no database, no QObject, no Qt
// Gui. Everything that needs to reason about LAYOUTS lives here so the same
// logic is shared by four callers that must never disagree: the validator
// and migration in ThemeService, the three QML render surfaces
// (ProjectionContentLayer, ThemedMonitor, ThemePreview), the two editors,
// and the test suite. A layout resolved differently in the mini-monitor
// than on the projector is the exact class of bug this file exists to make
// impossible.
//
// ── Why v3 exists ──────────────────────────────────────────────────────
// A v2 theme is one design: { version: 2, canvas, nodes }. Every slide of
// a deck therefore came out the same shape, and the only variation
// available was accidental — a group card hugs its members, so leaving the
// title empty collapsed it and read as a section divider.
//
// v3 replaces the single `nodes` array with a list of named `layouts`,
// each holding its own `nodes`, which is how a PowerPoint template carries
// a title slide, a section header, a two-content slide and so on. A
// presentation slide names the layout it is drawn with; every other
// content kind renders the default layout and never has to care.
//
//   { "version": 3,
//     "canvas":  { "width": 1920, "height": 1080 },
//     "layouts": [ { "id": "content", "name": "Title + content",
//                    "default": true, "nodes": [ ... ] }, ... ] }
//
// `canvas` stays at the top level: every layout of one theme paints to the
// same output, so a per-layout canvas could only ever be wrong.
//
// The authoring contract for all of this — the one handed to whoever writes
// a theme by hand — is qt/docs/theme-schema.md §9.

// ── Standard layout ids ────────────────────────────────────────────────
// A slide stores its layout as an id string, and that id is a SOFT
// reference — see resolveLayout(). Crater lets a deck and a theme move
// independently (per-deck override, per-output slot, per-kind default, all
// swappable mid-service), so a slide will routinely be rendered by a theme
// authored somewhere else entirely. PowerPoint never has to solve this
// because a deck owns its template.
//
// The answer is a shared vocabulary: a theme that names its designs with
// these ids will render another theme's deck as the author intended,
// because "section" means the same thing in both. Custom ids are legal and
// the visual editor creates them freely — they simply do not carry across
// a theme swap, and fall back to the default design.
inline constexpr auto kLayoutTitle     = "title";       // big centred title + subtitle
inline constexpr auto kLayoutSection   = "section";     // section divider, title only
inline constexpr auto kLayoutContent   = "content";     // heading over body
inline constexpr auto kLayoutTwoColumn = "twoColumn";   // heading over two text columns
inline constexpr auto kLayoutQuote     = "quote";       // large body, title as attribution
inline constexpr auto kLayoutPicture   = "picture";     // picture with heading / caption
inline constexpr auto kLayoutBlank     = "blank";       // background only

// The standard ids in the order a picker should offer them. Ordering is
// deliberate and matches the order a deck is usually built: title first,
// then dividers and content, with blank last.
QStringList standardLayoutIds();

// Human-readable default name for a standard id ("section" -> "Section
// divider"). Returns the id itself for a custom one, so a picker never
// renders an empty label.
QString defaultLayoutName(const QString& layoutId);

// ── Shape access ───────────────────────────────────────────────────────

// Every layout in the theme, in author order. Accepts a v2 map as well: a
// v2 theme reads as exactly one default layout wrapping its `nodes`, so
// callers never branch on version. Returns an empty list only for tokens
// with neither `layouts` nor `nodes`.
QVariantList layoutsOf(const QVariantMap& tokens);

// The layout a slide should be drawn with. Resolution order:
//   1. the layout whose id == layoutId,
//   2. the layout flagged "default": true,
//   3. the first layout.
// Returns an empty map only when the theme has no layouts at all.
//
// Falling back rather than failing is the load-bearing behaviour. A deck
// carries layout ids chosen under one theme and is projected under
// another; rendering nothing — or refusing to switch theme — would be
// worse than rendering that theme's default design. The id stays stored
// either way, so switching back restores the intended look.
QVariantMap resolveLayout(const QVariantMap& tokens, const QString& layoutId);

// The resolved layout's `nodes`, ready to hand straight to the renderer.
// This is the single call every render surface makes.
//
// `slideMediaId` binds the PICTURE placeholder. A container carrying
// data.linkage == "presentationImage" gets its data.mediaId replaced with
// the slide's, which is the whole implementation of per-slide pictures: a
// container already paints media from data.mediaId (NodeRenderer mounts
// MediaBackgroundLoader for any non-zero id), so substituting the id here
// means the paint path never learned anything new.
//
// A zero slideMediaId leaves the node's own mediaId in place, so a theme
// may ship a stock picture that a slide overrides rather than being forced
// to render an empty box until the operator picks something. Pass 0 for
// every non-presentation kind.
QVariantList layoutNodes(const QVariantMap& tokens,
                         const QString&     layoutId,
                         qint64             slideMediaId = 0);

// True when the theme actually defines a layout with this exact id, as
// opposed to resolveLayout() having fallen back. The slide editor uses it
// to mark a slide whose design is not available under the current theme,
// rather than silently showing the fallback as though it were chosen.
bool hasLayout(const QVariantMap& tokens, const QString& layoutId);

// ── Derived slots ──────────────────────────────────────────────────────

// Which per-slide fields a layout actually binds, DERIVED by scanning its
// nodes rather than declared alongside them. Returned as a map of bools:
//   { "title": bool, "body": bool, "subtitle": bool,
//     "bodyRight": bool, "image": bool }
//
// Derivation is the point. A declared slot list is a second source of
// truth that drifts the moment someone deletes a node in the visual editor
// and forgets the manifest, and the failure is silent: the slide editor
// offers a field that renders nowhere, or hides one the design needs. A
// scan cannot drift.
QVariantMap layoutSlots(const QVariantMap& layout);

// Same, for a layout id resolved against the theme.
QVariantMap layoutSlotsFor(const QVariantMap& tokens, const QString& layoutId);

// ── Migration ──────────────────────────────────────────────────────────

// Wraps a v2 token map ({version:2, canvas, nodes}) into the equivalent v3
// map with a single default layout. Idempotent on a map that is already
// v3, so it is safe to run over a row whose tokens_version column lagged
// behind its JSON — the exact trap V010's migration comment documents for
// the v1 -> v2 pass.
QVariantMap upgradeToV3(const QVariantMap& tokens);

}  // namespace crater::tokens
