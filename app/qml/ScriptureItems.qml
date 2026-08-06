pragma Singleton

import QtQuick
import Crater

// Builds canonical "scripture" schedule/projection items from Verse values.
//
// This lived inside ScriptureTab until narration needed it. Two things now
// construct scripture items — the operator picking verses in the library, and
// NarrationService hearing the preacher cite one — and they must produce
// exactly the same shape. Not approximately: the title format, the clipboard
// text, the DSL verse-number markup, and the progressive-highlight page split
// all have to match, or a verse that arrived by ear would render subtly
// differently from the same verse clicked by hand.
//
// So this is one definition with two callers rather than two definitions that
// agree today. ScriptureTab keeps thin wrappers over these functions, which is
// why none of its call sites changed.
//
// `fallbackCode` is the translation to attribute a verse to when the Verse
// value itself carries no translationCode — the caller's active translation
// for the library path, the operator's default for the narration path.
QtObject {

    // ── Single verse ────────────────────────────────────────────────────
    function fromVerse(verse, fallbackCode) {
        if (!verse || !verse.text || verse.text.length === 0) return null
        const code = verse.translationCode || fallbackCode
        return {
            kind:     "scripture",
            title:    verse.book + " " + verse.chapter + ":" + verse.verse + " (" + code + ")",
            subtitle: "",
            // Clipboard-ready text in the "quote + attribution" format. Built
            // here so it rides along to Preview/Live/Schedule — any surface
            // holding the item can copy without re-deriving the verse text.
            copyText: copyText([verse], fallbackCode),
            pages:    [{ label: verse.book + " " + verse.chapter + ":" + verse.verse, content: verse.text }],
            scriptureRef: {
                translationCode: code,
                book:            verse.book,
                chapter:         verse.chapter,
                verseStart:      verse.verse,
                verseEnd:        verse.verse
            }
        }
    }

    // ── Multi-verse passage ─────────────────────────────────────────────
    // Combined-item builder for multi-verse selections. Returns a single item
    // whose one page contains every selected verse, numbered, separated by
    // spaces — the "all on one slide" projection shape Q2 settled on. Title
    // collapses contiguous runs within the same book+chapter ("John 3:14-17"),
    // and falls back to a comma/semicolon list when the selection spans
    // multiple chapters or has gaps ("John 3:14, 16; Rom 5:8").
    //
    // scriptureRef carries the FIRST verse's coords so schedule → scripture
    // sync still has a single jump target. Schedule-row labels read the same
    // title field, so a multi-verse row reads as "John 3:14-17 (KJV)".
    function fromVerses(verses, fallbackCode) {
        if (!verses || verses.length === 0) return null
        const usable = verses.filter(function(v) { return v && v.text && v.text.length > 0 })
        if (usable.length === 0) return null
        if (usable.length === 1) return fromVerse(usable[0], fallbackCode)

        const code = usable[0].translationCode || fallbackCode
        const title = rangeTitle(usable) + " (" + code + ")"
        // Numbered verses so the operator can read which verse is which on
        // the slide. Two spaces between verses give the eye a parsing break
        // without bloating the layout the way line breaks would on themes
        // not designed for multi-verse content.
        //
        // The verse number is wrapped in DSL markup — bold (**…**) so it
        // reads as the heaviest run on the slide, and {color=yellow} (the
        // palette's #fdd835, the same gold the default theme uses for its
        // reference label) so it stands distinct from the verse body. This
        // is build-time, not render-time, on purpose: every surface that
        // shows this content (ProjectionContentLayer, ThemedMonitor, and the
        // Preview/Live page-list cards) feeds it through LyricsService.dslToHtml,
        // so a concrete color marker renders identically on all of them. A
        // per-theme "match the scriptureRef node color" scheme would only
        // reach the two resolveText paths and skip the thumbnail cards.
        // dslToHtml HTML-escapes the body text, so only our own markers are
        // interpreted; the verse body already flowed through the DSL parser
        // before this change, so no new escaping surface is introduced.
        // Trailing period ("3.") sits INSIDE the bold+color markup so the dot
        // inherits the same gold/bold styling as the digit — it reads as a
        // numbered marker rather than a bare digit colliding with the verse's
        // first word (and a separate unstyled dot would render plain white).
        // Passage builder — one styled run per verse, joined by two spaces.
        // activeIndex >= 0 dims every verse except that one (progressive-
        // highlight mode); -1 leaves them all bright (the default all-on-one-
        // slide look). Dimming is color-only ({color=gray}) so glyph metrics —
        // and therefore the binary-search auto-fit size — stay identical across
        // pages; stepping the highlight never resizes the text. (Note: gray
        // reads as "dimmed" on the dark backgrounds projection themes almost
        // always use; a light-background theme would want the inverse.)
        const composePassage = function(activeIndex) {
            return usable.map(function(v, j) {
                const num  = "{color=yellow}**" + v.verse + ".**{/color} "
                const body = (activeIndex < 0 || j === activeIndex)
                    ? v.text
                    : "{color=gray}" + v.text + "{/color}"
                return num + body
            }).join("  ")
        }

        // Progressive highlight (Settings > Scripture > Highlight current verse)
        // turns the passage into one page per verse — each page shows the whole
        // passage with that verse lit and the rest dimmed — so the normal slide
        // nav walks the highlight. Off → a single combined slide (unchanged).
        // Baked here at selection time, so a settings change applies to the
        // next projected passage.
        let pages
        if (SettingsService.highlightCurrentVerse) {
            pages = usable.map(function(v, i) {
                return { label:   v.book + " " + v.chapter + ":" + v.verse,
                         content: composePassage(i) }
            })
        } else {
            pages = [{ label: rangeTitle(usable), content: composePassage(-1) }]
        }

        const first = usable[0]
        const last  = usable[usable.length - 1]
        return {
            kind:     "scripture",
            title:    title,
            subtitle: "",
            // Flowing-quote clipboard text for the whole selection (see
            // copyText). Distinct from `composePassage` above, which numbers
            // each verse for the projection slide.
            copyText: copyText(usable, fallbackCode),
            pages:    pages,
            scriptureRef: {
                translationCode: code,
                book:            first.book,
                chapter:         first.chapter,
                verseStart:      first.verse,
                verseEnd:        last.verse
            }
        }
    }

    // Build the "copy to clipboard" string for a verse array — the format the
    // operator pastes into a YouTube description, sermon notes, etc. The verses
    // flow as one quoted passage (no inline verse numbers), then the reference
    // (book chapter:verse + translation) follows below on its own attribution
    // line:
    //
    //   "For God so loved the world... to condemn the world..."
    //
    //   - John 3:16-17 (KJV)
    //
    // Straight ASCII quotes (not typographic) keep the paste clean across web
    // inputs. Reuses rangeTitle so the reference shape matches the projection
    // title (collapsed ranges + translation) exactly. Returns "" when nothing
    // usable is passed, so callers can guard on empty instead of copying a
    // bare reference.
    function copyText(verses, fallbackCode) {
        if (!verses || verses.length === 0) return ""
        const usable = verses.filter(function(v) { return v && v.text && v.text.length > 0 })
        if (usable.length === 0) return ""
        const first = usable[0]
        const code = (first.translationCode && first.translationCode.length > 0)
                       ? first.translationCode : fallbackCode
        const body = usable.map(function(v) { return v.text }).join(" ")
        // Reference (book chapter:verse). rangeTitle collapses a multi-verse
        // selection into ranges; fall back to the first verse's own coords if
        // it ever returns empty so the attribution line is never blank.
        // Translation in parens only when we actually have a code.
        let ref = rangeTitle(usable)
        if (ref.length === 0 && first.book)
            ref = first.book + " " + first.chapter + ":" + first.verse
        const attribution = (code && code.length > 0) ? ref + " (" + code + ")" : ref
        return "\"" + body + "\"\n\n- " + attribution
    }

    // Compose a human reference string for a sorted verse array. Groups
    // verses by (book, chapter) and collapses each group's contiguous runs
    // into ranges. Numeric verse parsing tolerates the same shapes
    // ScriptureTab.verseMatches handles (plain "12", range "1-2",
    // subdivision "2a") by reading the leading integer.
    function rangeTitle(verses) {
        const groups = []        // [{book, chapter, verses:[int]}]
        let current = null
        for (let i = 0; i < verses.length; ++i) {
            const v = verses[i]
            const n = parseInt(String(v.verse), 10)
            if (isNaN(n)) continue
            if (!current || current.book !== v.book || current.chapter !== v.chapter) {
                current = { book: v.book, chapter: v.chapter, verses: [] }
                groups.push(current)
            }
            current.verses.push(n)
        }
        if (groups.length === 0) return ""
        return groups.map(function(g) {
            return g.book + " " + g.chapter + ":" + collapseRanges(g.verses)
        }).join("; ")
    }

    // [14,15,16,18] → "14-16, 18". Sorted-ascending precondition; the
    // builder already filters to that order via librarySelectedIndices'
    // sort guarantee in AppState.setLibrarySelected.
    function collapseRanges(nums) {
        if (nums.length === 0) return ""
        const out = []
        let start = nums[0], prev = nums[0]
        for (let i = 1; i < nums.length; ++i) {
            const n = nums[i]
            if (n === prev + 1) { prev = n; continue }
            out.push(start === prev ? String(start) : (start + "-" + prev))
            start = n; prev = n
        }
        out.push(start === prev ? String(start) : (start + "-" + prev))
        return out.join(", ")
    }
}
