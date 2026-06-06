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
`presentation` themes typically use custom text.

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
| `linkage`    | **yes**  | `scriptureRef` \| `scriptureText` \| `lyric` \| `custom` |
| `text`       | when `custom` | string (the literal text to show)                 |
| `autoResize` | no       | boolean — binary-search shrink-to-fit the box          |
| `maxFontSize`| no       | integer `> 0` — cap when `autoResize` is true          |

`linkage` decides what the box shows at runtime:
- `scriptureRef` → the reference label (e.g. "John 3:16").
- `scriptureText` → the verse body (the live verse text).
- `lyric` → the current song stanza.
- `custom` → the literal `data.text`.

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

## 7. Worked example

See `qt/docs/examples/scripture-aurora.theme.json` — a complete scripture theme
with an animated **mesh** background, the lower-third **scrim** above, and
**verse** + **reference** text boxes. Import it as-is, or use it as a template.

---

## 8. Checklist before importing

- [ ] `version` is `2`; `canvas.width`/`height` > 0; `nodes` non-empty.
- [ ] Every node has a unique `id`, a `kind`, and `style.x/y/width/height` in `0..100`.
- [ ] Every text node has `style.color` and `data.linkage`.
- [ ] Colors are `#rrggbb` or `#aarrggbb`; gradients have 2–6 stops.
- [ ] `z` orders: background (low) → scrim → text (high).
- [ ] No `data.mediaId` / imported `fontFamily` — JSON themes are vector + system-font only.
