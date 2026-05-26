#pragma once

#include "crater/value/UserFont.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QtQmlIntegration>

#include <memory>

namespace crater {

// Manages operator-imported font files.
//
// Where these come from: a `.craterheme` v2 bundle import (ARCHITECTURE.md
// §10) extracts each `fonts/<hash>.<ext>` entry and routes it through
// importFontFile() — that's the only public producer in v1. A future Font
// settings panel could expose direct user import; the API is already
// shaped for that.
//
// Lifecycle: construct EARLY in main.cpp (before QML loads). The
// constructor reads every row from user_fonts and calls
// QFontDatabase::addApplicationFontFromData on each so themes referencing
// a previously-imported family render correctly on the first paint of
// the session. Without this re-registration step, a font present in the
// DB but not loaded into QFontDatabase would silently fall back to a
// system font — the runtime gives no error, just the wrong glyphs.
class FontService : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QList<crater::UserFont> allFonts READ allFonts NOTIFY allFontsChanged)

public:
    explicit FontService(QObject* parent = nullptr);
    ~FontService() override;

    QList<crater::UserFont> allFonts();

    // Synchronously imports one font file:
    //   1. Read bytes, sniff TTF/OTF magic, sha256-hash.
    //   2. If a row with this hash already exists, return it (no-op).
    //   3. Copy to AppDataLocation/fonts/<hash>.<ext>.
    //   4. QFontDatabase::addApplicationFontFromData → read first family.
    //   5. INSERT row.
    //   6. Return the imported UserFont.
    //
    // On failure: returns an empty UserFont (id == 0) and lastError() is
    // populated. The on-disk copy is rolled back if registration succeeded
    // but the INSERT failed, so we never leave orphan font files.
    Q_INVOKABLE crater::UserFont importFontFile(QString path);

    // Look up by content hash. Used by the bundle importer to skip
    // re-importing a font we already have.
    Q_INVOKABLE crater::UserFont byHash(QString hash);

    // Look up the managed file path for a given family name. Returns
    // empty when the family was not registered through FontService —
    // e.g. system-installed fonts and the QRC-bundled Funnel Sans /
    // Lucide. The exporter uses this to decide which fonts can be
    // bundled; if filePathForFamily returns empty, the export records
    // the family name in the bundle WITHOUT the file (a system-font
    // reference that the importing machine resolves the usual way).
    Q_INVOKABLE QString filePathForFamily(QString family);

    Q_INVOKABLE QString lastError() const;

    // Removes a previously-imported font: unregisters it from
    // QFontDatabase, deletes the on-disk file, and DELETEs the row.
    // Returns true on success. Note: themes referencing this family
    // will fall back to a system substitute on their next render — no
    // dependency check is performed here, matching how other "remove"
    // paths in the project behave (operator's call to make).
    Q_INVOKABLE bool removeFont(qint64 id);

signals:
    void allFontsChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    QString m_lastError;

    void invalidateCache();
};

}  // namespace crater
