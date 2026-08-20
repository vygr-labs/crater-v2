#pragma once

#include <QByteArray>
#include <QString>

namespace crater {

// Looks one file's SHA-256 up in the body of a `sha256sum`-style checksum
// file, returning lowercase hex, or an empty string when the name is absent
// or no line is well-formed.
//
// Lives in crater-core, away from its only caller (the app-side
// UpdateService), for the same reason compareVersions does: it is pure text
// in, text out, so the headless test suite can cover it — and it must be
// covered, because it decides whether a 90 MB executable is allowed to run.
// A parser that quietly matches nothing looks identical to a release with no
// checksum, and the updater's response to both is to refuse, which is safe
// but would silently disable in-app installs forever.
//
// Accepted line shapes, all of which real tools emit:
//
//   <64 hex><two spaces>name          GNU coreutils, text mode
//   <64 hex><space>name               single-space variants
//   <64 hex><space>*name              binary mode (the '*' is a mode flag)
//   <64 hex><space>dir/sub/name       a path, when the sums were generated
//                                     from a directory walk
//
// Only the leaf file name is compared, so a checksum file listing paths still
// matches an asset named by GitHub. Lines that are not well-formed are
// skipped rather than treated as fatal: a checksum file is allowed to carry a
// comment or a blank line without invalidating the entries around it.
QString sha256ForName(const QByteArray& sums, const QString& name);

// True for exactly 64 lowercase hex characters.
bool isSha256Hex(const QString& s);

}  // namespace crater
