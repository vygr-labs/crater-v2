#pragma once

#include <QString>

namespace crater {

QString versionString();

// Ordering for release version strings ("0.6.1", "v1.0.0-rc2").
//
// Semver-lite, and deliberately not a full semver implementation: the only
// versions that ever reach this are the ones our own release workflow mints
// (.github/workflows/release.yml), which are always MAJOR.MINOR.PATCH with
// at most a pre-release suffix. The rules:
//
//   * A leading 'v' is ignored, so a git tag and a CMake project version
//     compare equal — "v0.6.1" == "0.6.1".
//   * The dot-separated numeric core compares component-wise as INTEGERS.
//     This is the whole reason the function exists: a string compare puts
//     0.10.0 below 0.9.0, which is the single most common way an updater
//     silently stops offering upgrades once the minor number hits double
//     digits.
//   * A missing component reads as 0, so "1.2" == "1.2.0".
//   * A pre-release suffix ranks BELOW the same numeric core, per semver:
//     1.0.0-rc1 < 1.0.0. Two suffixes on the same core compare as plain
//     strings, which happens to order alpha < beta < rc correctly.
//   * Anything unparseable counts as 0 rather than being rejected. This is
//     a security property, not laziness: these strings arrive over the
//     network, so a garbled one must neither crash the updater nor be
//     mistakable for an upgrade — sorting low guarantees both.
//
// Returns <0 when a sorts before b, 0 when they are equal, >0 when a sorts
// after b.
int compareVersions(const QString& a, const QString& b);

// Is `candidate` a release the machine running `current` does not have yet?
inline bool isNewerVersion(const QString& candidate, const QString& current)
{
    return compareVersions(candidate, current) > 0;
}

// Does this git tag name an application release — "v0.6.1", "1.2.3-rc1" —
// as opposed to some other tagged thing in the same repository?
//
// This exists because a repo holds more than app releases. Crater's already
// carries a published `data-v1` release for the bundled Bible and Strong's
// databases, and GitHub's "latest release" means most-recently-CREATED, not
// highest-version. Without this filter, publishing a `data-v2` bundle would
// make it "latest", the updater would read a version out of it, get junk,
// sort the junk low, and quietly report "up to date" from then on — a
// permanent silent failure caused by a routine action.
//
// True only when the part before any pre-release suffix is one or more
// dot-separated runs of digits, after an optional leading 'v'. So "v0.6.1"
// and "0.6" pass; "data-v1", "nightly" and "" do not.
bool isVersionTag(const QString& tag);

}  // namespace crater
