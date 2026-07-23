pragma Singleton

import QtQuick

// SearchFormat — shared search-result text formatting for the library tabs.
//
// Turns a plain string + the active query into `Text.StyledText` markup with
// the matched terms wrapped in a bold, accent-coloured span. The tokenizer
// mirrors the C++ FTS sanitizer (crater::db::buildFtsQuery): it honours
// "quoted phrases", ignores the OR/AND/NOT operator words and a leading '-',
// and drops sub-3-char terms the trigram tokenizer can't match — so the
// on-screen highlight lines up with what actually matched in the index.
//
// Usage in a delegate:
//   Text {
//       textFormat: Text.StyledText
//       text: SearchFormat.markup(modelData.text, queryText, Theme.color.brand)
//   }
QtObject {
    id: root

    // Extract the plain, lowercased terms that were actually searched.
    function terms(query) {
        var out = []
        if (!query) return out
        var re = /"([^"]+)"|(\S+)/g
        var m
        while ((m = re.exec(query)) !== null) {
            var isPhrase = m[1] !== undefined
            var t = (isPhrase ? m[1] : m[2]).trim()
            if (!isPhrase) {
                if (t === "OR" || t === "AND" || t === "NOT") continue
                while (t.charAt(0) === "-") t = t.substring(1)
            }
            if (t.length < 3) continue
            out.push(t.toLowerCase())
        }
        return out
    }

    // Escape the HTML-significant characters so StyledText renders the source
    // literally (verse text and lyrics can contain & and, rarely, < >).
    function _esc(s) {
        return String(s).replace(/&/g, "&amp;")
                        .replace(/</g, "&lt;")
                        .replace(/>/g, "&gt;")
    }

    // Normalize a colour (QML color value or hex/name string) to a 6-digit
    // "#rrggbb" that the StyledText <font color> parser always accepts —
    // stripping any alpha, which the CSS colour parser can choke on.
    function _hex(c) {
        if (c === undefined || c === null) return "#4c9be8"
        if (typeof c === "string") {
            if (c.charAt(0) === "#" && c.length === 9) return "#" + c.substring(3)
            return c
        }
        if (c.r !== undefined) {
            var f = function (x) {
                var v = Math.round(x * 255).toString(16)
                return v.length < 2 ? "0" + v : v
            }
            return "#" + f(c.r) + f(c.g) + f(c.b)
        }
        return "#4c9be8"
    }

    // Return `text` as StyledText with each matched term wrapped in a bold
    // accent span. With nothing to highlight it returns the escaped text
    // unchanged (still valid StyledText, so a delegate can bind textFormat
    // unconditionally when it wants).
    function markup(text, query, color) {
        var plain = text || ""
        var ts = terms(query)
        if (ts.length === 0) return _esc(plain)

        var lower = plain.toLowerCase()
        var ranges = []
        for (var i = 0; i < ts.length; i++) {
            var t = ts[i], from = 0, idx
            while ((idx = lower.indexOf(t, from)) !== -1) {
                ranges.push([idx, idx + t.length])
                from = idx + t.length
            }
        }
        if (ranges.length === 0) return _esc(plain)

        ranges.sort(function (a, b) { return a[0] - b[0] })
        // Merge overlapping / adjacent match ranges into clean spans.
        var merged = [ranges[0].slice()]
        for (var r = 1; r < ranges.length; r++) {
            var last = merged[merged.length - 1]
            if (ranges[r][0] <= last[1]) {
                if (ranges[r][1] > last[1]) last[1] = ranges[r][1]
            } else {
                merged.push(ranges[r].slice())
            }
        }

        var col = _hex(color)
        var out = "", cursor = 0
        for (var k = 0; k < merged.length; k++) {
            var s = merged[k][0], e = merged[k][1]
            out += _esc(plain.substring(cursor, s))
            out += '<b><font color="' + col + '">'
                 + _esc(plain.substring(s, e)) + '</font></b>'
            cursor = e
        }
        out += _esc(plain.substring(cursor))
        return out
    }
}
