#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

namespace crater {

// QML-callable wrapper around the pure free functions in crater::lyrics
// (see LyricsDSL.h). Lives as a singleton under the `Crater` QML URI; the
// instance is constructed in app/src/main.cpp and registered via
// `qmlRegisterSingletonInstance("Crater", 1, 0, "LyricsService", ...)`.
//
// All methods are Q_INVOKABLE so QML can call them from binding expressions
// — that's the typical access pattern: NodeRenderer's `text:` binding
// resolves to `LyricsService.dslToHtml(item.pages[i].content, transform)`.
// The service holds no state; methods are const and reentrant.
//
// Why this thin wrapper instead of registering the namespace directly:
// Q_INVOKABLE requires a QObject host. The alternative — exposing the
// namespace via Q_NAMESPACE + QML_NAMESPACE — works for enums but not for
// free functions in Qt 6.11. A small QObject keeps the binding surface
// uniform with the rest of the services.
class LyricsService : public QObject
{
    Q_OBJECT

public:
    explicit LyricsService(QObject* parent = nullptr);

    // Render a DSL string as an HTML fragment for `Text { textFormat: Text.RichText }`.
    // The input may contain '\n' line separators; each line is parsed
    // independently (per DSL rule: marks can't cross line boundaries) and
    // joined with `<br>` in the output. `textTransform` applies CSS-style
    // case folding to visible text only — markers and color values are not
    // affected. Accepts "" (default), "uppercase", "lowercase", "capitalize";
    // unknown values are no-ops.
    Q_INVOKABLE QString dslToHtml(const QString& dsl,
                                  const QString& textTransform = QString()) const;

    // Strip DSL markers from a single line, leaving the plain text only.
    // Useful for raw-text mirrors, accessibility hooks, and copy-to-clipboard
    // flows where formatting should be dropped.
    Q_INVOKABLE QString flattenLine(const QString& dslLine) const;

    // Seven canonical named colors used by the editor toolbar swatch.
    // Returned in display order (red → orange → yellow → green → blue →
    // purple → gray); QML enumerates this for the picker grid.
    Q_INVOKABLE QStringList namedColors() const;

    // Resolve a name or hex value to a `#rrggbb` / `#rgb` hex string,
    // suitable for direct use in CSS (`color:` properties) or QColor
    // construction. Returns an empty string if the input is unrecognized —
    // callers should treat that as "no color override" and inherit from
    // the surrounding context.
    Q_INVOKABLE QString resolveColor(const QString& nameOrHex) const;
};

}  // namespace crater
