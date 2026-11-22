// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

#include "profile/ProfileSettings.h"

#include "db/DbPaths.h"

#include <QDir>
#include <QMetaType>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>

namespace crater::profile {

namespace {

enum class Kind { Bool, Int, String, StringList };

struct KeySpec {
    const char* key;
    Kind        kind;
};

// The per-profile preference keys and their value types. The type drives
// both the export (registry values come back as strings on Windows, so they
// are normalised here) and the import validation.
const QList<KeySpec>& specs()
{
    static const QList<KeySpec> s{
        { "Settings/showCcli",                  Kind::Bool   },
        { "Settings/showLogoByDefault",         Kind::Bool   },
        { "Settings/defaultScriptureVersion",   Kind::String },
        { "Settings/showVerseNumbers",          Kind::Bool   },
        { "Settings/highlightCurrentVerse",     Kind::Bool   },
        { "Settings/splitPartChars",            Kind::Int    },
        { "Settings/splitDivider",              Kind::Bool   },
        { "Settings/showScriptureFooter",       Kind::Bool   },
        { "Settings/showStrongsTab",            Kind::Bool   },
        { "Settings/showSongAuthor",            Kind::Bool   },
        { "Settings/showSongCcli",              Kind::Bool   },
        { "Settings/autoAdvance",               Kind::Bool   },
        { "Settings/autoAdvanceDelaySeconds",   Kind::Int    },
        { "Settings/autoAdvanceLoop",           Kind::Bool   },
        { "Settings/mediaDefaultFit",           Kind::String },
        { "Settings/globalSearchActions",       Kind::String },
        { "Settings/showMatchedLyricSnippet",   Kind::Bool   },
        { "Settings/highlightSongMatches",      Kind::Bool   },
        { "Settings/highlightScriptureMatches", Kind::Bool   },
        { "Settings/highlightStrongsMatches",   Kind::Bool   },
        // This profile's view of the shared Bible library: translation codes.
        { "Settings/translationOrder",          Kind::StringList },
        { "Settings/hiddenTranslations",        Kind::StringList },
    };
    return s;
}

const KeySpec* specFor(QStringView key)
{
    for (const KeySpec& s : specs())
        if (key == QLatin1String(s.key)) return &s;
    return nullptr;
}

// Set in a profile's own store once it has taken over the translation
// lists from the machine-wide store (inheritMachineWideLists). Not a
// preference: never exported, and a reset keeps it.
const QString& listsInheritedKey()
{
    static const QString k = QStringLiteral("Profile/translationListsInherited");
    return k;
}

bool isDefaultRoot(const QString& root)
{
    return QDir::cleanPath(QDir(root).absolutePath())
        == QDir::cleanPath(db::DbPaths::appRootDir());
}

// Normalise a stored value to the key's type. Registry values come back as
// strings ("true", "20"), INI values likewise; QVariant's conversions handle
// both.
QVariant typed(const KeySpec& s, const QVariant& v)
{
    switch (s.kind) {
    case Kind::Bool:   return QVariant(v.toBool());
    case Kind::Int:    return QVariant(v.toInt());
    case Kind::String: return QVariant(v.toString());
    // An INI file stores a one-code list as a plain string; toStringList
    // turns that back into a list.
    case Kind::StringList: return QVariant(v.toStringList());
    }
    return {};
}

// Strict check for values arriving from an archive. Bounds mirror what
// SettingsService itself accepts, so nothing written here can later be
// read back as something the service would have refused.
bool acceptable(const KeySpec& s, const QVariant& v)
{
    const int t = v.metaType().id();
    switch (s.kind) {
    case Kind::Bool:
        return t == QMetaType::Bool;
    case Kind::Int: {
        if (t != QMetaType::Int && t != QMetaType::LongLong && t != QMetaType::Double)
            return false;
        const double d = v.toDouble();
        return d >= 1 && d <= 600;
    }
    case Kind::String: {
        if (t != QMetaType::QString) return false;
        const QString str = v.toString();
        if (str.size() > 4096) return false;
        if (QLatin1String(s.key) == QLatin1String("Settings/mediaDefaultFit"))
            return str == QLatin1String("contain") || str == QLatin1String("cover")
                || str == QLatin1String("stretch");
        if (QLatin1String(s.key) == QLatin1String("Settings/defaultScriptureVersion")) {
            static const QRegularExpression re(QStringLiteral("^[A-Za-z0-9 ._-]{1,32}$"));
            return re.match(str).hasMatch();
        }
        return true;
    }
    case Kind::StringList: {
        // JSON arrays arrive as QVariantList. Every entry must look like a
        // translation code, the same rule defaultScriptureVersion follows.
        if (t != QMetaType::QStringList && t != QMetaType::QVariantList) return false;
        const QVariantList list = v.toList();
        if (list.size() > 500) return false;
        static const QRegularExpression re(QStringLiteral("^[A-Za-z0-9 ._-]{1,32}$"));
        for (const QVariant& e : list)
            if (e.metaType().id() != QMetaType::QString || !re.match(e.toString()).hasMatch())
                return false;
        return true;
    }
    }
    return false;
}

}  // namespace

const QStringList& perProfileSettingKeys()
{
    static const QStringList keys = [] {
        QStringList out;
        for (const KeySpec& s : specs()) out.append(QString::fromLatin1(s.key));
        return out;
    }();
    return keys;
}

bool isPerProfileSettingKey(QStringView key)
{
    return specFor(key) != nullptr;
}

QString outputThemesKey(const QString& outputId)
{
    return QStringLiteral("Outputs/") + outputId + QStringLiteral("/themes");
}

std::unique_ptr<QSettings> openGlobalSettings()
{
    if (QStandardPaths::isTestModeEnabled()) {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        return std::make_unique<QSettings>(QDir(dir).filePath(QStringLiteral("global-settings.ini")),
                                           QSettings::IniFormat);
    }
    // Same organisation + application names every service already uses, so
    // this is the one registry hive (Windows) / config file (elsewhere).
    return std::make_unique<QSettings>(QStringLiteral("Voyager Labs"), QStringLiteral("Crater"));
}

std::unique_ptr<QSettings> openProfileSettingsAt(const QString& root)
{
    if (root.isEmpty() || isDefaultRoot(root)) return openGlobalSettings();
    return std::make_unique<QSettings>(QDir(root).filePath(QStringLiteral("settings.ini")),
                                       QSettings::IniFormat);
}

std::unique_ptr<QSettings> openProfileSettings()
{
    if (db::DbPaths::isDefaultDataDir()) return openGlobalSettings();
    return openProfileSettingsAt(db::DbPaths::dataDir());
}

QVariantMap readProfilePreferences(const QString& root)
{
    QVariantMap out;
    const auto store = openProfileSettingsAt(root);
    for (const KeySpec& s : specs()) {
        const QString k = QString::fromLatin1(s.key);
        if (store->contains(k)) out.insert(k, typed(s, store->value(k)));
    }
    return out;
}

int writeProfilePreferences(const QString& root, const QVariantMap& values)
{
    const auto store = openProfileSettingsAt(root);
    int written = 0;
    for (auto it = values.constBegin(); it != values.constEnd(); ++it) {
        const KeySpec* s = specFor(it.key());
        if (!s || !acceptable(*s, it.value())) continue;
        store->setValue(it.key(), typed(*s, it.value()));
        ++written;
    }
    store->sync();
    return written;
}

void copyProfileSettings(const QString& fromRoot, const QString& toRoot)
{
    const auto from = openProfileSettingsAt(fromRoot);
    const auto to   = openProfileSettingsAt(toRoot);
    if (isDefaultRoot(toRoot)) return;   // never rewrite the machine store wholesale

    for (const KeySpec& s : specs()) {
        const QString k = QString::fromLatin1(s.key);
        if (from->contains(k)) to->setValue(k, typed(s, from->value(k)));
    }
    // A copy of a profile that already took the machine-wide lists over has
    // its own, so it must not take them again.
    if (from->contains(listsInheritedKey())) to->setValue(listsInheritedKey(), true);
    // Output theme pins. The output list itself is machine-wide, so walk it
    // from the global store.
    const auto global = openGlobalSettings();
    const QStringList ids = global->value(QStringLiteral("Outputs/ids")).toStringList();
    for (const QString& id : ids) {
        const QString k = outputThemesKey(id);
        if (from->contains(k)) to->setValue(k, from->value(k));
    }
    to->sync();
}

bool inheritMachineWideLists(const QSettings& machine, QSettings& store)
{
    if (store.contains(listsInheritedKey())) return false;
    bool copied = false;
    for (const char* key : { "Settings/translationOrder", "Settings/hiddenTranslations" }) {
        const QString k = QString::fromLatin1(key);
        if (store.contains(k) || !machine.contains(k)) continue;
        store.setValue(k, typed(*specFor(k), machine.value(k)));
        copied = true;
    }
    store.setValue(listsInheritedKey(), true);
    store.sync();
    return copied;
}

void clearProfileSettings(const QString& root)
{
    const auto store = openProfileSettingsAt(root);
    for (const KeySpec& s : specs()) store->remove(QString::fromLatin1(s.key));
    // Theme pins name themes in the profile's own database, which a reset
    // replaces, so they go too. The output list itself is machine-wide.
    const auto global = openGlobalSettings();
    const QStringList ids = global->value(QStringLiteral("Outputs/ids")).toStringList();
    for (const QString& id : ids) store->remove(outputThemesKey(id));
    store->sync();
}

}  // namespace crater::profile
