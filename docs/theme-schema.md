# Crater Theme JSON Schema (v2)

This document is the **authoring contract** for a Crater theme. Hand it to a
designer — or to Claude — and ask for a theme; the output is a single JSON file
that imports via **Themes tab → Import JSON**. The app validates on import and
reports any field-level error (e.g. `nodes[2].style.opacity must be 0..1`), so a
malformed theme is rejected cleanly rather than rendering broken.

A theme is a **node graph**: containers and text boxes positioned by *percent*
on a fixed canvas. There is no HTML/CSS — just this JSON. It supports solid
colors, **animated gradients** (including transparent fade-to-black scrims), and
**system fonts**. It does **not** support bundled images/videos/custom font
files via JSON — those use the `.craterheme` bundle export/import instead.

---

## 1. File format

```jsonc
{
  "name": "Aurora Scripture",                 // required, non-empty
  "kind": "scripture",                        // required: song | scripture | presentation
  "tokens": {
    "version": 2,                             // required, exactly 2
    "canvas": { "width": 1920, "height": 1080 },   // required, both > 0
    "nodes": [ /* one or more nodes, see §2 */ ]    // required, non-empty
  }
}
```

`kind` decides which content the text boxes can bind to (see `linkage`, §4):
`scripture` themes bind reference + verse text; `song` themes bind lyric text;
`presentation` themes bind a deck slide's title + body.

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
| `linkage`    | **yes**  | `scriptureRef` \| `scriptureText` \| `lyric` \| `presentationTitle` \| `presentationBody` \| `custom` |
| `text`       | when `custom` | string (the literal text to show)                 |
| `autoResize` | no       | boolean — binary-search shrink-to-fit the box          |
| `maxFontSize`| no       | integer `> 0` — cap when `autoResize` is true          |

`linkage` decides what the box shows at runtime:
- `scriptureRef` → the reference label (e.g. "John 3:16"). For non-scripture
  items this is the item's **title**, which is the usual way to show a song name.
- `scriptureText` → the verse body (the live verse text).
- `lyric` → the current song stanza.
- `presentationTitle` → the current slide's heading (presentation decks).
- `presentationBody` → the current slide's body text.
- `custom` → the literal `data.text`.

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

---

## 9. Checklist before importing

- [ ] `version` is `2`; `canvas.width`/`height` > 0; `nodes` non-empty.
- [ ] Every node has a unique `id`, a `kind`, and `style.x/y/width/height` in `0..100`.
- [ ] Every text node has `style.color` and `data.linkage`.
- [ ] Colors are `#rrggbb` or `#aarrggbb`; gradients have 2–6 stops.
- [ ] `z` orders: background (low) → scrim → text (high).
- [ ] No `data.mediaId` / imported `fontFamily` — JSON themes are vector + system-font only.
