# Crater Theme JSON Schema (v3)

This document is the **authoring contract** for a Crater theme. Hand it to a
designer — or to Claude — and ask for a theme; the output is a single JSON file
that imports via **Themes tab → Import JSON**. The app validates on import and
reports any field-level error (e.g. `nodes[2].style.opacity must be 0..1`), so a
malformed theme is rejected cleanly rather than rendering broken.

> **In-app shortcut.** The theme editor's **Design with AI** button copies a
> self-contained version of this contract to the clipboard, ready to paste into
> any assistant, and takes the reply straight back into the editor. The prompt
> it builds lives in `qt/core/src/ThemePrompt.cpp` and restates the rules below
> rather than linking to them, because the model on the other end cannot read
> this file. **Anything you change here has to be changed there too** — the
> `theme_prompt` test suite pins the parts a wrong answer hinges on, but it
> cannot know about a rule that was never written down twice.

A theme is a **node graph**: containers and text boxes positioned by *percent*
on a fixed canvas. There is no HTML/CSS — just this JSON. It supports solid
colors, **animated gradients** (including transparent fade-to-black scrims), and
**system fonts**. It does **not** support bundled images/videos/custom font
files via JSON — those use the `.craterheme` bundle export/import instead.

Since **v3** a theme carries a list of named **layouts** rather than a single
node graph, which is what lets one presentation theme hold a title slide, a
section divider, a two-column slide and so on — see §9. Everything below
describes one layout's nodes, and applies unchanged. A v2 file still imports:
it reads as a theme with exactly one layout.

---

## 1. File format

```jsonc
{
  "name": "Aurora Scripture",                 // required, non-empty
  "kind": "scripture",                        // required: song | scripture | presentation
  "tokens": {
    "version": 3,                             // required, exactly 3
    "canvas": { "width": 1920, "height": 1080 },   // required, both > 0
    "layouts": [                              // required, non-empty — see §9
      {
        "id": "content",                      // required, unique within the theme
        "name": "Title + content",            // required, non-empty
        "default": true,                      // at most one layout may set this
        "nodes": [ /* one or more nodes, see §2 */ ]   // required, non-empty
      }
    ]
  }
}
```

A **v2** file is still accepted and is the smaller thing to write when a theme
only ever needs one design:

```jsonc
  "tokens": {
    "version": 2,
    "canvas": { "width": 1920, "height": 1080 },
    "nodes": [ /* ... */ ]
  }
```

It is read as a theme with a single default layout, and is rewritten to v3 the
first time the app saves it.

`kind` decides which content the text boxes can bind to (see `linkage`, §4):
`scripture` themes bind reference + verse text; `song` themes bind lyric text;
`presentation` themes bind a deck slide's title, subtitle, body, second column
and picture.

> `kind` is a *default*, not a restriction. Linkage is validated globally, so a
> song theme may legitimately use `scriptureRef` — for a song item that resolves
> to the song title, which is how several themes show the title above the lyric.

---

## 2. Node — common shape

Every node:

```jsonc
{
  "id": "bg",                  // required, unique within the theme
  "kind": "container",         // required: "container" | "text"
  "style": { /* §2.1 + §3 or §4 */ },
  "data":  { /* §3 or §4 */ }
}
```

### 2.1 `style` — common to all nodes

| Field      | Required | Type / range                         | Notes |
|------------|----------|--------------------------------------|-------|
| `x`        | **yes**  | number `0..100`                      | Left edge, % of canvas width |
| `y`        | **yes**  | number `0..100`                      | Top edge, % of canvas height |
| `width`    | **yes**  | number `0..100`                      | % of canvas width |
| `height`   | **yes**  | number `0..100`                      | % of canvas height |
| `z`        | no       | integer                              | Paint order; higher = on top. Default 0 |
| `opacity`  | no       | number `0..1`                        | Node opacity. Default 1 |
| `rotation` | no       | finite number (degrees)              | Default 0 |

Nodes are painted in `z` order (ties broken by array order). Put backgrounds at
low `z`, text at high `z`.

---

## 3. Container nodes (`kind: "container"`)

Backgrounds, scrims, color blocks. `style` adds:

| Field                       | Required | Type / range            | Notes |
|-----------------------------|----------|-------------------------|-------|
| `backgroundColor`           | no       | hex color or `""`       | Solid fill. Ignored when a gradient fill is set |
| `borderTopLeftRadius` …     | no       | number `>= 0`           | Four corner fields; the renderer paints their average |

`data` adds the **fill**:

```jsonc
"data": {
  "fill": {
    "type": "gradient",          // "solid" (default) | "gradient"
    "gradient": {                // required when type == "gradient"
      "style":  "mesh",          // "linear" | "radial" | "conic" | "mesh"
      "colors": ["#0f172a", "#312e81", "#1e3a8a"],   // 2..6 hex stops (alpha OK)
      "angle":  0,               // degrees; linear/conic only (0=L→R, 90=top→bottom)
      "speed":  0.3,             // flow rate (conic/mesh only)
      "animate": true            // flow on/off (conic/mesh only)
    }
  }
}
```

Gradient styles:
- **linear** — straight ramp along `angle`. Static (clamped endpoints). `angle 90` = top→bottom.
- **radial** — center→edge ramp. Static.
- **conic** — sweep around center; rotates when `animate`.
- **mesh** — flowing "aurora" blend of the stops; the flagship animated look.

Stops carry **alpha** (`#aarrggbb`). In gradient mode the container's solid base
is dropped to transparent, so transparent stops reveal whatever is *behind* the
node — this is how a scrim works (see §6).

> Color format: `#rgb`, `#rrggbb`, or `#aarrggbb` (alpha first, Qt-native).

### The picture placeholder

A container may also carry a `data.linkage`, and it has exactly one legal
value:

```jsonc
"data": { "linkage": "presentationImage" }
```

That turns the container into the design's **picture box**: at render time it is
handed the slide's own picture instead of the theme's. A container already
paints whatever `data.mediaId` points at, so this changes only where the id
comes from — which is the entire implementation of per-slide pictures.

The theme's own `data.mediaId` stays in place underneath and is what renders
when a slide has picked nothing, so a picture design can ship a stock image
rather than an empty box. (JSON themes cannot reference media — see §1 — so a
stock image means a `.craterheme` bundle.)

Anything other than `presentationImage` is rejected on import rather than
ignored: a typo here leaves an author staring at a picture design that never
shows a picture.
> `#00000000` = transparent, `#000000` = opaque black, `#e6000000` = ~90% black.

---

## 4. Text nodes (`kind: "text"`)

`style` adds typography:

| Field                  | Required | Type / range                                  |
|------------------------|----------|-----------------------------------------------|
| `color`                | **yes**  | hex color                                     |
| `fontFamily`           | no       | system font name (e.g. `"Segoe UI"`); omit for default |
| `fontPixelSize`        | no       | integer `> 0` (at 1080p canvas scale)         |
| `fontWeight`           | no       | `100..900` in steps of 100                    |
| `fontItalic`           | no       | boolean                                       |
| `letterSpacing`        | no       | number `-2..10`                               |
| `lineHeightMultiplier` | no       | number `0.5..3.0`                             |
| `textAlign`            | no       | `left` \| `center` \| `right`                 |
| `verticalAlign`        | no       | `start` \| `center` \| `end`                  |
| `textTransform`        | no       | `none` \| `uppercase` \| `lowercase` \| `capitalize` |
| `textShadowColor`      | no       | hex color, or `""` for no shadow (the on/off sentinel) |
| `textShadowOffsetX/Y`  | no       | number `-50..50`                              |
| `textShadowBlur`       | no       | number `0..50`                                |

`data`:

| Field        | Required | Type / values                                          |
|--------------|----------|--------------------------------------------------------|
| `linkage`    | **yes**  | `scriptureRef` \| `scriptureText` \| `lyric` \| `presentationTitle` \| `presentationSubtitle` \| `presentationBody` \| `presentationBodyRight` \| `custom` |
| `text`       | when `custom` | string (the literal text to show)                 |
| `autoResize` | no       | boolean — binary-search shrink-to-fit the box          |
| `maxFontSize`| no       | integer `> 0` — cap when `autoResize` is true          |

`linkage` decides what the box shows at runtime:
- `scriptureRef` → the reference label (e.g. "John 3:16"). For non-scripture
  items this is the item's **title**, which is the usual way to show a song name.
- `scriptureText` → the verse body (the live verse text).
- `lyric` → the current song stanza.
- `presentationTitle` → the current slide's heading (presentation decks).
- `presentationSubtitle` → the slide's subtitle. A title slide's second line.
- `presentationBody` → the current slide's body text.
- `presentationBodyRight` → the slide's second column, for a two-column design.
- `custom` → the literal `data.text`.

> Which of these a layout binds is what decides **which fields the slide editor
> offers** for a slide on that design. That is derived by scanning the layout's
> nodes, not declared anywhere — delete the `presentationBodyRight` box and the
> Right column field stops appearing, with nothing else to keep in step.

> A deck slide's **speaker notes** have no linkage on purpose. They are never
> rendered to the audience — only the stage / confidence display shows them, and
> that display is deliberately unthemed. There is no way to author a theme that
> leaks them onto the main screen.

**Inline formatting** in `custom`/content text supports a small DSL:
`**bold**`, and `{color=yellow}…{/color}` (named or `#hex`). Plain text is valid.

> Tip: set `autoResize: true` with a `maxFontSize` for verse/lyric boxes so long
> passages shrink to fit instead of overflowing. Use a drop shadow
> (`textShadowColor` + `textShadowBlur`) for legibility over busy backgrounds.

---

## 5. Positioning model

- Origin top-left; everything is **percent of the 1920×1080 canvas**.
- A full-canvas background is `x:0, y:0, width:100, height:100`.
- A "lower third" is roughly `y:66, height:34` (or `y:55, height:45` for a taller fade).
- Text boxes should sit *inside* their visual region — the renderer centers and
  (optionally) auto-fits text within the box you give it.

---

## 6. Recipe: lower-third fade-to-black scrim

A scrim darkens the bottom of the screen so text stays legible over any
background. It is a container in the lower region with a **vertical linear
gradient from transparent to black**, placed *above* the background and *below*
the text:

```jsonc
{
  "id": "scrim",
  "kind": "container",
  "style": { "x": 0, "y": 55, "width": 100, "height": 45, "z": 1 },
  "data": { "fill": { "type": "gradient", "gradient": {
    "style": "linear",
    "angle": 90,                              // vertical: top → bottom
    "colors": ["#00000000", "#e6000000"],     // transparent → ~90% black
    "animate": false
  }}}
}
```

The clear top blends into the background; the opaque bottom anchors the text.
If it looks inverted, swap the two colors or set `angle` to `270`.

---

## 7. Content-hugging cards — the **group**

A short verse in a fixed box leaves dead space below it. The clean way to get a
lower-third that hugs its content is a **group container** (a "card"): it holds
its text members, stacks them, hugs the total, and pins to the bottom. Members
keep **auto-fit** and are positioned by the card — no per-node linking.

> **Live output only (for now).** The card lays out on the projection / NDI
> output; the editor canvas shows each node at its configured box.

### `data.group` — a container becomes a card

```jsonc
"group": {
  "members": ["reference", "verse"],  // node ids, top → bottom
  "gap": 1.5,                          // % between members
  "padTop": 4, "padBottom": 4, "padX": 8,   // % inset
  "anchor": "bottom"                   // "bottom" (default) | "center"
}
```

`anchor` picks where the hugged card sits inside the container's configured box:

- **bottom** (default) — the card's bottom edge pins to the box bottom and the
  card grows upward. This is the lower-third look: the screen margin under the
  text is fixed, so a long verse eats space *above* rather than sliding the whole
  block toward the screen edge.
- **center** — the card centres vertically in the box and grows both ways. This
  is what slide content wants, and what the built-in **presentation** themes use:
  a slide with a heading and two lines and a slide with a heading and eight lines
  should both read as centred. Bottom-anchoring a title-only slide would drop a
  lone heading to the floor of its box.

Because the card hugs its members, an empty member collapses to nothing. That is
the whole layout system for presentation decks: one theme with a centred
`["title", "body"]` card renders a title-only slide as a section divider, a
body-only slide as plain content, and both together as a heading over content —
with no per-slide layout setting for the deck and the theme to disagree about.

- Put it on the **container** that carries the scrim (its gradient fill renders
  behind the whole card). The container's configured box: its **bottom edge**
  (`y + height`) is where the card sits (your screen margin); its **width** is the
  card width (members fill it minus `padX`).
- Each **member** keeps its own style. A member's **height** is its *own* auto-fit
  max region — a long verse shrinks to fit its height; the card then hugs whatever
  the members actually render to.
- The card **bottom-anchors** and grows upward: short verse → short card; long
  verse → taller card. No dead space, and the verse still auto-fits.

### Recipe: bottom-anchored card (see §8)
1. **bg** — full-canvas gradient.
2. **card** (container) — the scrim gradient + `data.group` listing `["reference","verse"]`, with the bottom box edge at your margin.
3. **reference** (text) — `autoResize:false`, its `height` = the label's area.
4. **verse** (text) — `autoResize:true` + `maxFontSize`, its `height` = the verse's max area.

### Lower-level primitives (advanced / back-compat)
`data.autoHeight` (a container hugs another node's content — `{source}` or
`{from,to}`) and `data.autoPosition` (`{place:"above"|"below", source, gap}`)
still work for one-off layouts, but the **group** is the recommended path for
cards: it owns the layout, so alignment is exact and there's nothing to
cross-link.

---

## 8. Worked examples

`qt/docs/examples/scripture-aurora.theme.json` — a complete scripture theme
with an animated **mesh** background, a lower-third **scrim** that **hugs** the
verse (§7), and **verse** + **reference** text that stack above the screen
bottom. Import it as-is, or use it as a template.

`qt/docs/examples/presentation-lectern.theme.json` — a **presentation** theme
("Lectern") for sermon-notes decks. Worth reading for two things the schema
makes easy to get wrong:

- **Decoration must be fixed-position, not content-adjacent.** The group card
  (§7) hugs its members and re-centres per slide, so a rule drawn to bracket the
  text would sit correctly on a two-line slide and wrongly on an eight-line one.
  Lectern's accent rule is therefore a full-height **page** margin rule, which
  has nothing to misalign with.
- **`autoResize` fits to the node's OWN box height, so that box is a size
  control, not just a bounding box.** Lectern's title box is 26% tall rather
  than the ~20% the text needs, because at 22% a two-line title could only reach
  95px while a one-line title reached the 116px cap — section-divider slides
  rendered visibly smaller than content slides for no reason the author intended.
  The card hugs actual rendered height, so an oversized box costs no dead space.

`qt/docs/examples/presentation-stream-strap.theme.json` — a compact broadcast
lower third. It shows the one §7 feature that is easy to miss: a container can
carry **both a fill and `data.group`**, so the panel itself hugs the text
instead of being a fixed box drawn behind it. The strap therefore measures
~13.6% of frame on a title-only slide and ~19.5% with a body, with no dead
space at either size, and the background can never be the wrong height.

Its brand rule is pinned near the strap's **bottom**, because bottom-anchored
is the one edge a hugging card holds still. Anything pinned to the top of a
hugging card drifts with content length.

`scripture-stream-strap.theme.json` and `song-stream-strap.theme.json` are the
matching **scripture** and **song** straps, so a service can cut between a
verse, a lyric and a sermon point without the graphics changing identity. Same
band, rule, margins and type; only the hierarchy flips. A sermon point is its
own headline, so presentation runs title-large over body-small. A verse and a
lyric are the content, so those run a small `scriptureRef` kicker over
large body text — `scriptureRef` resolves to the item title for non-scripture
kinds, which is how the song strap labels itself with the song name.

Sizing note: a four-line stanza is the case that hurts. Lyrics are fitted to
their own box, so a lower third that stays compact for two lines shrinks four
to roughly 33px and grows to ~29% of frame. Two-line song pages stream far
better than four-line ones.

---

## 9. Layouts — one theme, several designs

A PowerPoint template does not hold one slide design, it holds a set: a title
slide, a section header, a two-content slide, a picture slide. Crater themes
work the same way from **v3** on. `tokens.layouts` is that set, in the order a
picker offers them:

```jsonc
"tokens": {
  "version": 3,
  "canvas": { "width": 1920, "height": 1080 },
  "layouts": [
    { "id": "title",   "name": "Title slide",     "nodes": [ /* ... */ ] },
    { "id": "section", "name": "Section divider", "nodes": [ /* ... */ ] },
    { "id": "content", "name": "Title + content", "default": true,
                                                  "nodes": [ /* ... */ ] }
  ]
}
```

| Field     | Required | Notes |
|-----------|----------|-------|
| `id`      | **yes**  | Unique within the theme. Prefer a standard id — see below |
| `name`    | **yes**  | Non-empty. What both editors list the design by |
| `default` | no       | At most one layout. Omitted everywhere → the first layout wins |
| `nodes`   | **yes**  | Non-empty; the same node graph §2–§7 describe |

`canvas` stays at the top level, outside the layouts. Every design of one theme
paints to the same output, so a per-layout canvas could only ever be wrong.

Node `id`s only have to be unique **within** a layout. Two designs may both call
their heading `title`, and a `group`'s `members` (§7) always refer to node ids in
the same layout.

### Which design a slide gets

A presentation slide stores a layout **id**. Every other content kind — songs,
scripture, media — stores nothing and always renders the default, which is why a
song theme is fine with the single implicit layout a v2 file gives it.

Resolution, in order:

1. the layout whose `id` matches the slide's,
2. the layout flagged `"default": true`,
3. the first layout.

Step 2 is the load-bearing one. A slide's layout id is a **soft reference**: it
is looked up in whatever theme is rendering at the time, and if that theme has
never heard of it, the slide falls back to that theme's default rather than
failing. Crater lets a deck and a theme move independently — per-deck override,
per-output slot, per-kind default, all swappable mid-service — so a slide is
routinely drawn by a theme authored somewhere else entirely. PowerPoint never
has to solve this, because there a deck owns its template.

The id **stays stored** through the fallback, so switching back restores the
intended design. The slide editor marks such a slide "Not in this theme" rather
than quietly showing the fallback as though it were chosen, so an operator does
not "fix" a theme swap by clicking around and overwrite ids that would have come
back on their own.

### The standard ids

Because ids are matched across themes, a shared vocabulary is what makes a deck
portable. A theme that names its designs with these will render another theme's
deck the way its author intended:

| `id`         | Default name      | Typically binds |
|--------------|-------------------|-----------------|
| `title`      | Title slide       | title + subtitle |
| `section`    | Section divider   | title |
| `content`    | Title + content   | title + body |
| `twoColumn`  | Two columns       | title + body + right column |
| `quote`      | Quote             | body large, title as attribution |
| `picture`    | Picture           | picture + title + body |
| `blank`      | Blank             | background only |

Custom ids are legal and the theme editor creates them freely. They simply do
not carry across a theme swap, and fall back to the default design.

`name` is free text and does not have to match the table — a Yoruba-language
theme can call `section` whatever it likes and portability is unaffected, since
matching is on `id` alone.

### What a design binds

There is no field listing which slide fields a layout uses. It is **derived** by
scanning the layout's nodes for the presentation linkages (§3, §4):

| Node | Linkage | Slide field |
|------|---------|-------------|
| text      | `presentationTitle`     | Title |
| text      | `presentationSubtitle`  | Subtitle |
| text      | `presentationBody`      | Body |
| text      | `presentationBodyRight` | Right column |
| container | `presentationImage`     | Picture |

Derivation rather than declaration is deliberate. A declared slot list is a
second source of truth that drifts the moment someone deletes a node in the
visual editor and forgets the manifest, and it drifts silently: the slide editor
would offer a field that renders nowhere, or hide one the design needs.

**Speaker notes** are on every design and are not in the table. They have no
linkage at all — see the note in §4.

---

## 10. Checklist before importing

- [ ] `version` is `3` with a non-empty `layouts` (or `2` with a non-empty
      `nodes`); `canvas.width`/`height` > 0.
- [ ] Every layout has a unique `id` and a non-empty `name`; at most one sets
      `"default": true`; each holds a non-empty `nodes`.
- [ ] Every node has an `id` unique **within its layout**, a `kind`, and
      `style.x/y/width/height` in `0..100`.
- [ ] Every text node has `style.color` and `data.linkage`.
- [ ] Colors are `#rrggbb` or `#aarrggbb`; gradients have 2–6 stops.
- [ ] `z` orders: background (low) → scrim → text (high).
- [ ] No `data.mediaId` / imported `fontFamily` — JSON themes are vector + system-font only.
