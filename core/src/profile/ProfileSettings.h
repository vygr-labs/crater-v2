#pragma once

#include <QSettings>
#include <QString>
#include <QStringList>
#include <QStringView>
#include <QVariantMap>

#include <memory>

namespace crater::profile {

// Which preferences follow the active profile and where they are stored.
// See ARCHITECTURE.md §12.2 for the split and the reasoning behind it.
//
// Global (machine) settings stay in the one registry hive / config file
// every Crater install already uses: screens and outputs, NDI, window and
// UI preferences, UI language, updates. They describe this computer and
// its operator, not a congregation's content.
//
// Per-profile settings are the content preferences EasyWorship keeps per
// profile: what a slide shows (CCLI, verse numbers, authors), scripture
// and song behaviour, the default media fit, search presentation. Plus
// each output's pinned themes, because theme ids only mean something
// inside one profile's database.
//
// The Default profile keeps its per-profile values in the same registry
// hive as before, under the same keys, so an existing install reads
// exactly what it always did. Every other profile keeps them in
// <profile root>/settings.ini.

// "Settings/..." keys owned by the active profile. Anything SettingsService
// persists that is not listed here is global.
const QStringList& perProfileSettingKeys();
bool isPerProfileSettingKey(QStringView key);

// The per-profile output key suffix: "Outputs/<id>/themes".
QString outputThemesKey(const QString& outputId);

// The machine-wide store (registry on Windows).
std::unique_ptr<QSettings> openGlobalSettings();

// The per-profile store of the profile rooted at `root`. For the Default
// profile's root this is the machine-wide store itself.
std::unique_ptr<QSettings> openProfileSettingsAt(const QString& root);

// The per-profile store of the active profile (DbPaths::dataDir()).
std::unique_ptr<QSettings> openProfileSettings();

// Snapshot of the per-profile preference keys (not output theme pins) of
// the profile at `root`, for export. Only keys that are actually stored.
QVariantMap readProfilePreferences(const QString& root);

// Write preference values into the profile at `root`. Unknown keys and
// values of an unexpected type are skipped, so a hand-edited archive
// cannot smuggle arbitrary registry keys in. Returns how many were written.
int writeProfilePreferences(const QString& root, const QVariantMap& values);

// Copy every per-profile value, output theme pins included, from one
// profile root to another. Used when duplicating a profile, where theme ids
// stay valid because the database is copied whole.
void copyProfileSettings(const QString& fromRoot, const QString& toRoot);

}  // namespace crater::profile
