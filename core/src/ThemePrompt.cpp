#include "crater/ThemePrompt.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>

namespace crater::prompt {
namespace {

// ── Kind-specific fragments ────────────────────────────────────────────
// Only three things actually vary by kind: which linkages are legal, what
// the sample content looks like, and whether layouts are in play. Splitting
// on exactly those keeps one copy of the schema instead of three that drift.

QString kindIntro(const QString& kind)
{
    if (kind == QLatin1String("song")) {
        return QStringLiteral(
            "This is a SONG theme. It renders one stanza of lyrics at a time,\n"
            "changing every few seconds while the congregation sings. Legibility\n"
            "from the back of a room matters more than anything else here.\n");
    }
    if (kind == QLatin1String("scripture")) {
        return QStringLiteral(
            "This is a SCRIPTURE theme. It renders one Bible verse at a time\n"
            "together with its reference. Verses vary wildly in length, from a\n"
            "handful of words to several lines, so the design has to hold both.\n");
    }
    return QStringLiteral(
        "This is a PRESENTATION theme. It renders sermon-notes slides: a\n"
        "heading, body lines, sometimes a subtitle, a second column or a\n"
        "picture. It works like a PowerPoint template, so it carries SEVERAL\n"
        "named designs rather than one, and each slide picks the one it wants.\n");
}

QString linkageTable(const QString& kind)
{
    if (kind == QLatin1String("song")) {
        return QStringLiteral(
            "  \"lyric\"        the current stanza. This is the main content.\n"
            "  \"scriptureRef\" resolves to the SONG TITLE for a song item. This\n"
            "                 is the normal way to label the screen with the\n"
            "                 song's name.\n"
            "  \"custom\"       literal text you supply in data.text.\n");
    }
    if (kind == QLatin1String("scripture")) {
        return QStringLiteral(
            "  \"scriptureText\" the verse body. This is the main content.\n"
            "  \"scriptureRef\"  the reference label, e.g. \"John 3:16\".\n"
            "  \"custom\"        literal text you supply in data.text.\n");
    }
    return QStringLiteral(
        "  \"presentationTitle\"     the slide heading.\n"
        "  \"presentationSubtitle\"  the slide subtitle, e.g. a title slide's\n"
        "                          second line.\n"
        "  \"presentationBody\"      the slide body text.\n"
        "  \"presentationBodyRight\" the second column of a two-column design.\n"
        "  \"custom\"                literal text you supply in data.text.\n"
        "\n"
        "A CONTAINER may also carry data.linkage, with exactly one legal\n"
        "value: \"presentationImage\". That marks the container as the design's\n"
        "picture box, and the slide's own picture is painted into it.\n");
}

QString sampleContent(const QString& kind)
{
    if (kind == QLatin1String("song")) {
        return QStringLiteral(
            "Design against this sample content:\n"
            "  song title : \"Amazing Grace\"\n"
            "  stanza     : \"Amazing grace, how sweet the sound\n"
            "                That saved a wretch like me\n"
            "                I once was lost, but now am found\n"
            "                Was blind, but now I see\"\n"
            "\n"
            "A stanza is normally two to four lines. Four-line stanzas are the\n"
            "case that hurts, so make sure the lyric box is tall enough that\n"
            "four lines still read large.\n");
    }
    if (kind == QLatin1String("scripture")) {
        return QStringLiteral(
            "Design against this sample content:\n"
            "  reference : \"John 3:16\"\n"
            "  verse     : \"For God so loved the world, that he gave his only\n"
            "               begotten Son, that whosoever believeth in him\n"
            "               should not perish, but have everlasting life.\"\n"
            "\n"
            "Verses run from six words to roughly sixty. The verse box must\n"
            "survive the long end without the short end looking lost.\n");
    }
    return QStringLiteral(
        "Design against this sample content:\n"
        "  title        : \"The God Who Pursues\"\n"
        "  subtitle     : \"Luke 15\"\n"
        "  body         : \"He does not wait at the edge of the far country.\n"
        "                  He runs.\"\n"
        "  right column : \"The elder son stayed home and was just as lost.\"\n"
        "\n"
        "A body is one to eight short lines. A title is one or two lines.\n");
}

// The layouts chapter, and the sample skeleton, are presentation-only. A song
// or scripture theme renders one design and has no way to select a second, so
// handing the model a layouts vocabulary there would only invite it to author
// designs nothing in the app can ever reach.
QString layoutsSection(const QString& kind)
{
    if (kind != QLatin1String("presentation")) {
        return QStringLiteral(
            "## Designs\n"
            "\n"
            "This kind renders ONE design. Emit a single entry in \"layouts\",\n"
            "with \"id\": \"content\" and \"default\": true.\n");
    }
    return QStringLiteral(
        "## Designs (the important part)\n"
        "\n"
        "\"layouts\" is a LIST, and it is what makes this a template rather\n"
        "than a single slide. Author four to seven designs. Each is a full,\n"
        "independent node graph.\n"
        "\n"
        "Use these ids where the design matches, because a slide stores the id\n"
        "and carries it between themes. An id another theme also uses renders\n"
        "the way the author intended after a theme swap. An invented id falls\n"
        "back to the default design instead.\n"
        "\n"
        "  \"title\"      Title slide          binds title + subtitle\n"
        "  \"section\"    Section divider      binds title only\n"
        "  \"content\"    Title + content      binds title + body\n"
        "  \"twoColumn\"  Two columns          binds title + body + right column\n"
        "  \"quote\"      Quote                body large, title as attribution\n"
        "  \"picture\"    Picture              picture + title + body\n"
        "  \"blank\"      Blank                background only\n"
        "\n"
        "Exactly one layout sets \"default\": true. Make it the \"content\" one.\n"
        "The default is what non-presentation content renders and what an\n"
        "unrecognised slide falls back to, so it must be the safe general case.\n"
        "\n"
        "The designs must read as ONE family. Same background treatment, same\n"
        "type family, same accent colour, same margins. What changes between\n"
        "them is the arrangement and the size of the type, not the identity.\n"
        "\n"
        "There is no field listing which slide fields a design uses. The app\n"
        "works it out by scanning the design's nodes for the linkages above, so\n"
        "a design binds a field simply by containing a node with that linkage.\n"
        "\n"
        "Node ids only have to be unique WITHIN one design. Two designs may\n"
        "both call their heading \"title\".\n");
}

QString startFromSection(const QVariantMap& startFrom)
{
    if (startFrom.isEmpty()) return QString();

    const QJsonDocument doc(QJsonObject::fromVariantMap(startFrom));
    const QString json = QString::fromUtf8(doc.toJson(QJsonDocument::Indented));

    return QStringLiteral(
        "\n"
        "## The design I have now\n"
        "\n"
        "Below is my current theme. Evolve it rather than starting over: keep\n"
        "what works, and keep the canvas and the set of designs unless the\n"
        "brief asks otherwise. Return the same envelope, complete. Do not\n"
        "return a patch or a diff.\n"
        "\n"
        "```json\n") + json + QStringLiteral("```\n");
}

}  // namespace

QString designPrompt(const QString&     kind,
                     const QString&     brief,
                     const QVariantMap& startFrom)
{
    const QString safeKind =
        (kind == QLatin1String("song") || kind == QLatin1String("scripture")
         || kind == QLatin1String("presentation"))
            ? kind
            : QStringLiteral("presentation");

    const QString trimmedBrief = brief.trimmed();

    // An empty brief is a first-class path, not a fallback to nothing: it is
    // the "surprise me" case, and the model needs to be told that explicitly
    // or it stalls and asks a clarifying question instead of designing.
    const QString briefSection =
        trimmedBrief.isEmpty()
            ? QStringLiteral(
                  "## The brief\n"
                  "\n"
                  "I have not specified a look. Design something you think is\n"
                  "genuinely excellent. Commit to a point of view rather than\n"
                  "playing it safe, and tell me nothing about it. Just build it.\n")
            : QStringLiteral("## The brief\n\n") + trimmedBrief + QStringLiteral("\n");

    return QStringLiteral(R"PROMPT(You are designing a display theme for Crater, a live presentation app that
puts song lyrics, Bible verses and sermon slides on a screen during a church
service.

Reply with ONE JSON object and NOTHING else. No commentary before or after,
no explanation of your choices. A program reads your reply.

)PROMPT")
        + kindIntro(safeKind)
        + QStringLiteral("\n")
        + briefSection
        + QStringLiteral("\n")
        + sampleContent(safeKind)
        + QStringLiteral(R"PROMPT(
## The output

One JSON object in exactly this shape:

{
  "name": "<a short, evocative name you choose>",
  "kind": ")PROMPT")
        + safeKind
        + QStringLiteral(R"PROMPT(",
  "tokens": {
    "version": 3,
    "canvas": { "width": 1920, "height": 1080 },
    "layouts": [
      {
        "id": "content",
        "name": "Title + content",
        "default": true,
        "nodes": [ ... ]
      }
    ]
  }
}

"kind" must stay exactly as written above. Do not change it.

## The canvas

A fixed 1920x1080 stage. EVERY position and size is a PERCENTAGE of that
canvas, never a pixel. Origin is top left. A full-bleed background is
x 0, y 0, width 100, height 100.

The one exception is type size, which is in pixels at this canvas scale and
is scaled with the output. So fontPixelSize 64 means 64px on a 1080p screen.

## Nodes

A design is a flat list of nodes painted in "z" order, low to high. Every
node:

{
  "id": "bg",              // required, unique within its design
  "kind": "container",     // required: "container" or "text"
  "style": { ... },
  "data":  { ... }
}

style, on every node:

  x, y, width, height   required, number 0..100 (percent)
  z                     optional integer, paint order, higher is on top
  opacity               optional number 0..1
  rotation              optional number, degrees

## Containers

Backgrounds, colour blocks, scrims, cards. style also takes:

  backgroundColor              hex, or "" for none. Ignored when a gradient
                               fill is set.
  borderTopLeftRadius, borderTopRightRadius,
  borderBottomLeftRadius, borderBottomRightRadius
                               numbers >= 0. The renderer paints the average
                               of the four, so set them all the same.

data takes the fill:

"data": {
  "fill": {
    "type": "gradient",
    "gradient": {
      "style":   "mesh",
      "colors":  ["#0f172a", "#312e81", "#1e3a8a"],
      "angle":   0,
      "speed":   0.3,
      "animate": true
    }
  }
}

  linear   straight ramp along "angle". Static. angle 90 is top to bottom.
  radial   centre to edge. Static.
  conic    sweep around the centre. Rotates when "animate" is true.
  mesh     a slow flowing blend of the stops. This is the flagship look and
           the one worth reaching for on a full-bleed background.

"colors" takes two to six hex stops. "speed" and "animate" apply to conic
and mesh only.

Colours are "#rgb", "#rrggbb", or "#aarrggbb" with the ALPHA FIRST, which is
Qt's order and not CSS's. So #00000000 is transparent, #000000 is opaque
black, and #e6000000 is about 90 percent black.

A gradient stop's alpha shows what is BEHIND the node, which is how a scrim
works. A scrim is a container over the background and under the text, with a
vertical linear gradient from transparent to near-black:

{
  "id": "scrim",
  "kind": "container",
  "style": { "x": 0, "y": 55, "width": 100, "height": 45, "z": 1 },
  "data": { "fill": { "type": "gradient", "gradient": {
    "style": "linear", "angle": 90,
    "colors": ["#00000000", "#e6000000"], "animate": false } } }
}

## Text

style also takes:

  color                  required, hex
  fontFamily             a font installed on the machine. See the list below.
  fontPixelSize          integer > 0
  fontWeight             100..900 in steps of 100
  fontItalic             true or false
  letterSpacing          -2..10
  lineHeightMultiplier   0.5..3.0
  textAlign              "left", "center" or "right"
  verticalAlign          "start", "center" or "end"
  textTransform          "none", "uppercase", "lowercase", "capitalize"
  textShadowColor        hex, or "" for no shadow
  textShadowOffsetX      -50..50
  textShadowOffsetY      -50..50
  textShadowBlur         0..50

data takes:

  linkage      required. What the box shows at runtime. Legal values below.
  text         required only when linkage is "custom"
  autoResize   true shrinks the text to fit its own box
  maxFontSize  integer > 0, the cap when autoResize is true

Note that verticalAlign uses "start" and "end", NOT "top" and "bottom".

Legal linkage values for this kind:

)PROMPT")
        + linkageTable(safeKind)
        + QStringLiteral(R"PROMPT(
Inline formatting inside text supports **bold** and {color=#ffcc00}...
{/color}. Plain text is fine.

autoResize fits the text to that node's OWN height, so the box height is a
size control and not just a bounding box. Give a box more height than the
text needs and the text renders LARGER, up to maxFontSize. Set autoResize
true with a sensible maxFontSize on any box holding content of variable
length.

## Cards that hug their content

A short verse in a tall fixed box leaves dead space under it. A container
can instead become a CARD that stacks its members, hugs their real height
and pins itself:

"data": {
  "group": {
    "members": ["reference", "verse"],
    "gap": 1.5,
    "padTop": 4, "padBottom": 4, "padX": 8,
    "anchor": "bottom"
  }
}

"members" are node ids in the same design, listed top to bottom. "gap" and
the pads are percentages.

  anchor "bottom"   the card's bottom edge pins to the bottom of the
                    container's box and the card grows upward. This is the
                    lower-third look: the screen margin under the text stays
                    fixed and long content eats space above.
  anchor "center"   the card centres in its box and grows both ways. This is
                    what slide content wants.

The card container keeps its own fill, so one node can be both the panel and
the layout. Members keep their own styles and their own autoResize.

Because the card hugs, an EMPTY member collapses to nothing. A centred card
holding a title and a body therefore renders a title-only slide as a proper
section divider with no gap where the body would have been.

Anything you want to sit still, such as a rule or a logo, must be its own
fixed node and NOT a card member. A card re-centres per slide, so decoration
placed inside it drifts with the content length.

)PROMPT")
        + layoutsSection(safeKind)
        + QStringLiteral(R"PROMPT(
## Fonts

System fonts only, by exact family name. You cannot ship a font file. Safe
choices on Windows:

  Segoe UI Variable Display, Segoe UI, Bahnschrift, Corbel, Candara,
  Constantia, Cambria, Georgia, Palatino Linotype, Franklin Gothic Medium,
  Trebuchet MS, Verdana, Arial, Times New Roman, Impact, Consolas

Pick ONE family and vary weight and size. Two families only if you have a
real reason, and then one for headings and one for body.

## What makes this good

Judge it as a screen seen from the back of a room, not as a page.

- Contrast is the whole job. Light type on a dark ground, or dark type on a
  light ground. Never mid tone on mid tone.
- Body type should not go below about 34px at this canvas scale. Content
  type wants to be 40 to 90px. A title slide can go to 120px.
- Keep everything inside a 6 percent margin. Projectors and TV overscan eat
  the edges.
- Layer as background at z 0, scrim or card at z 1 to 5, text at z 10 and
  up. Never leave text at the same z as the thing behind it.
- Text over a busy or animated background needs either a scrim or a shadow.
  Both is usually too much.
- Restraint reads as expensive. Two or three colours from one family plus a
  single accent beats six.
- Do not centre everything by reflex. An asymmetric layout with a strong
  left edge often reads better and is easier to scan.
- Line height around 1.2 to 1.35 for multi-line content.
- If you use a mesh or conic gradient, keep "speed" low, around 0.2 to 0.4.
  Fast motion behind live text is exhausting to read.

## Hard rules

- Output ONE JSON object. No markdown fences, no prose, no trailing commas,
  no comments in the JSON.
- Invent NO fields. Anything not listed above is rejected on import.
- No "mediaId" and no imported font files. This format carries vector shapes,
  colours, gradients and system fonts only. There is no way to reference an
  image from it.
- Every node needs an id unique within its design, a kind, and x, y, width
  and height in 0..100.
- Every text node needs style.color and data.linkage.
- Every design needs a non-empty id, a non-empty name, and at least one node.
- Exactly one design sets "default": true.
)PROMPT")
        + startFromSection(startFrom);
}

}  // namespace crater::prompt
