#!/usr/bin/env bash
# Build, deploy, and package Crater for macOS distribution.
#
# Mirrors qt/scripts/release.ps1 (the Windows driver): same version-parsing,
# same Bible-DB resolution order, same dist/ layout. Produces a .app bundle,
# a portable .zip of that bundle, and a .dmg installer.
#
# Designed to run from a clean shell on a dev machine, and to be invoked
# verbatim by the GitHub Actions release workflow.
#
# Flags:
#   --qt-dir <path>          Qt macOS kit (clang_64 / macos). Otherwise
#                            $QT_ROOT_DIR (set by install-qt-action), then
#                            Homebrew, then /Applications/Qt.
#   --version <X.Y.Z>        Overrides version parsed from CMakeLists.txt.
#                            CI passes the git tag here (with leading 'v'
#                            stripped) so the tag is the authoritative
#                            version for the artifacts.
#   --skip-build             Skip cmake configure + build (iterate on packaging).
#   --skip-dmg               Skip the .dmg step; produce .zip only.
#   --skip-zip               Skip the .zip step; produce .dmg only.
#   --clean                  Wipe build-release/ and dist/ before starting.

set -euo pipefail

# ── Pretty output ──────────────────────────────────────────────────────────
# Honor NO_COLOR; fall back to no-op when stdout is not a TTY (CI logs).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_STEP=$'\033[36m'; C_DONE=$'\033[32m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_STEP=''; C_DONE=''; C_WARN=''; C_OFF=''
fi
step() { printf '%s>>> %s%s\n' "$C_STEP" "$*" "$C_OFF"; }
done_msg() { printf '%s    %s%s\n' "$C_DONE" "$*" "$C_OFF"; }
warn() { printf '%sWARNING: %s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }

# ── Args ───────────────────────────────────────────────────────────────────
QT_DIR=''
CONFIGURATION='Release'
VERSION_OVERRIDE=''
SKIP_BUILD=0
SKIP_DMG=0
SKIP_ZIP=0
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qt-dir)     QT_DIR="$2"; shift 2 ;;
        --version)    VERSION_OVERRIDE="$2"; shift 2 ;;
        --config)     CONFIGURATION="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-dmg)   SKIP_DMG=1; shift ;;
        --skip-zip)   SKIP_ZIP=1; shift ;;
        --clean)      CLEAN=1; shift ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Release-specific build dir, parallel to Windows' build-release/; never
# collides with the dev tree's build/.
BUILD_DIR="$QT_ROOT/build-release"
DIST_ROOT="$QT_ROOT/dist"
APP_STAGE_DIR="$DIST_ROOT/Crater"           # the staging directory
APP_BUNDLE="$APP_STAGE_DIR/crater.app"
PACKAGING_DIR="$QT_ROOT/packaging"

# Bible DB: same fixed Release asset as the Windows driver. The local sibling
# path is checked first as a courtesy to dev machines that still have the
# electron repo cloned.
BIBLE_DB_PATH="$PACKAGING_DIR/bibles.sqlite"
BIBLE_DB_LOCAL_SOURCE="$QT_ROOT/../electron/src/assets/default/databases/bibles.sqlite"
BIBLE_DB_URL='https://github.com/vygr-labs/crater-v2/releases/download/data-v1/bibles.sqlite'
BIBLE_DB_SHA256='d86eed30ff7e28f213a06dcc7e6d7439ea3c851756f593a999b110247a7e044c'

# ── Resolve Qt ─────────────────────────────────────────────────────────────
# 1. --qt-dir wins.  2. $QT_ROOT_DIR (install-qt-action).  3. common installer
# paths.  We look for macdeployqt as the sentinel since that's the binary the
# script actually invokes; presence of bin/macdeployqt means the kit is real.
resolve_qt_dir() {
    if [[ -n "$QT_DIR" ]]; then
        [[ -x "$QT_DIR/bin/macdeployqt" ]] || {
            echo "Explicit --qt-dir missing bin/macdeployqt: $QT_DIR" >&2; exit 1; }
        echo "$QT_DIR"; return
    fi
    if [[ -n "${QT_ROOT_DIR:-}" && -x "$QT_ROOT_DIR/bin/macdeployqt" ]]; then
        echo "$QT_ROOT_DIR"; return
    fi
    # Common dev-box locations: Homebrew (Apple Silicon + Intel) and the
    # official Qt installer's default install root. Newest version wins.
    local roots=( /opt/homebrew/opt/qt /usr/local/opt/qt )
    for r in "${roots[@]}"; do
        if [[ -x "$r/bin/macdeployqt" ]]; then echo "$r"; return; fi
    done
    if [[ -d "$HOME/Qt" ]]; then
        # /Users/you/Qt/6.11.1/macos/bin/macdeployqt
        local newest
        newest=$(/bin/ls -1 "$HOME/Qt" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -t. -k1,1n -k2,2n -k3,3n -r | head -n1 || true)
        if [[ -n "$newest" && -x "$HOME/Qt/$newest/macos/bin/macdeployqt" ]]; then
            echo "$HOME/Qt/$newest/macos"; return
        fi
    fi
    cat >&2 <<EOF
Could not locate a Qt macOS kit. Tried:
  --qt-dir parameter        (not supplied)
  \$QT_ROOT_DIR             ${QT_ROOT_DIR:-not set}
  /opt/homebrew/opt/qt, /usr/local/opt/qt
  \$HOME/Qt/<version>/macos

Pass --qt-dir explicitly, e.g.:
  ./scripts/release.sh --qt-dir \$HOME/Qt/6.11.1/macos
EOF
    exit 1
}

# ── Version ────────────────────────────────────────────────────────────────
CMAKE_VERSION=$(sed -nE 's/.*project\(Crater[[:space:]]+VERSION[[:space:]]+([0-9.]+).*/\1/p' \
    "$QT_ROOT/CMakeLists.txt" | head -n1)
if [[ -z "$CMAKE_VERSION" ]]; then
    echo "Could not parse 'project(Crater VERSION ...)' from CMakeLists.txt" >&2
    exit 1
fi
VERSION="${VERSION_OVERRIDE:-$CMAKE_VERSION}"
if [[ -n "$VERSION_OVERRIDE" && "$VERSION_OVERRIDE" != "$CMAKE_VERSION" ]]; then
    warn "Version override ($VERSION_OVERRIDE) differs from CMakeLists ($CMAKE_VERSION). Using override for artifact names; binary will still report $CMAKE_VERSION."
fi
step "Crater version: $VERSION"

QT_DIR_RESOLVED=$(resolve_qt_dir)
step "Qt kit: $QT_DIR_RESOLVED"
MACDEPLOYQT="$QT_DIR_RESOLVED/bin/macdeployqt"

# ── Clean ──────────────────────────────────────────────────────────────────
if [[ $CLEAN -eq 1 ]]; then
    step 'Cleaning build/ and dist/'
    rm -rf "$BUILD_DIR" "$DIST_ROOT"
fi

# ── Configure + build ──────────────────────────────────────────────────────
# Same generator + caching story as the Windows driver: Ninja Multi-Config
# is the only generator that honors CMAKE_<LANG>_COMPILER_LAUNCHER (so sccache
# / ccache works on this script too), and Multi-Config preserves the
# `cmake --build --config Release` semantics used everywhere else.
if [[ $SKIP_BUILD -eq 0 ]]; then
    step "Configuring CMake (Qt at $QT_DIR_RESOLVED)"
    export CMAKE_PREFIX_PATH="$QT_DIR_RESOLVED"
    if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
        step "Reusing existing cache in $BUILD_DIR"
        cmake -S "$QT_ROOT" -B "$BUILD_DIR"
    else
        cmake -S "$QT_ROOT" -B "$BUILD_DIR" \
            -G 'Ninja Multi-Config'
    fi
    step "Building $CONFIGURATION"
    cmake --build "$BUILD_DIR" --config "$CONFIGURATION" --parallel
fi

# Locate the built .app. MACOSX_BUNDLE ON in qt/app/CMakeLists.txt produces
# crater.app; Ninja Multi-Config drops it at <build>/crater.app (no per-config
# subdir, because RUNTIME_OUTPUT_DIRECTORY is pinned to ${CMAKE_BINARY_DIR}).
APP_CANDIDATES=(
    "$BUILD_DIR/crater.app"
    "$BUILD_DIR/$CONFIGURATION/crater.app"
)
BUILT_APP=''
for c in "${APP_CANDIDATES[@]}"; do
    if [[ -d "$c" ]]; then BUILT_APP="$c"; break; fi
done
if [[ -z "$BUILT_APP" ]]; then
    echo "crater.app not found. Looked in: ${APP_CANDIDATES[*]}" >&2
    exit 1
fi
step "Built bundle: $BUILT_APP"

# ── Stage ──────────────────────────────────────────────────────────────────
step "Staging to $APP_STAGE_DIR"
rm -rf "$APP_STAGE_DIR"
mkdir -p "$APP_STAGE_DIR"
# -R preserves symlinks inside the .app (frameworks rely on Versions/Current
# symlinks; a plain `cp -r` would dereference them and bloat the bundle).
cp -R "$BUILT_APP" "$APP_BUNDLE"

# ── macdeployqt ────────────────────────────────────────────────────────────
# -qmldir scans our QML and bundles only the modules we actually import,
# the same trick we use on Windows. Without it macdeployqt would still
# ship the lot, just much larger.
# We deliberately do NOT pass -dmg here. macdeployqt's built-in DMG creator
# produces a minimal disk image with no background, no /Applications drop
# target, and a fixed window size. We build a nicer DMG via hdiutil below.
step 'Running macdeployqt'
"$MACDEPLOYQT" "$APP_BUNDLE" \
    -qmldir="$QT_ROOT/app/qml" \
    -always-overwrite

# ── Stage Bible DB ─────────────────────────────────────────────────────────
# Importer (core/src/import/ElectronDataImporter.cpp) walks up from the exe
# looking for legacy/bibles.sqlite. On macOS the exe is at
#   crater.app/Contents/MacOS/crater
# so we stage at
#   crater.app/Contents/MacOS/legacy/bibles.sqlite
# which is the hop-0 hit. Not strictly idiomatic macOS layout (data usually
# lives in Contents/Resources/), but it matches the Windows behavior the
# importer is written for. Revisit when the importer learns about
# Contents/Resources/.
step 'Staging Bible database'
if [[ ! -f "$BIBLE_DB_PATH" ]]; then
    if [[ -f "$BIBLE_DB_LOCAL_SOURCE" ]]; then
        step "Importing bibles.sqlite from sibling electron tree"
        mkdir -p "$PACKAGING_DIR"
        cp "$BIBLE_DB_LOCAL_SOURCE" "$BIBLE_DB_PATH"
    else
        step "Downloading bibles.sqlite from $BIBLE_DB_URL"
        mkdir -p "$PACKAGING_DIR"
        curl -fSL --retry 3 -o "$BIBLE_DB_PATH" "$BIBLE_DB_URL"
    fi
fi
# shasum -a 256 is the macOS-native equivalent of sha256sum.
ACTUAL_SHA=$(shasum -a 256 "$BIBLE_DB_PATH" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$BIBLE_DB_SHA256" ]]; then
    rm -f "$BIBLE_DB_PATH"
    echo "bibles.sqlite SHA-256 mismatch. Expected $BIBLE_DB_SHA256, got $ACTUAL_SHA. The cached/downloaded file has been removed; rerun to refetch." >&2
    exit 1
fi
LEGACY_DIR="$APP_BUNDLE/Contents/MacOS/legacy"
mkdir -p "$LEGACY_DIR"
cp "$BIBLE_DB_PATH" "$LEGACY_DIR/bibles.sqlite"
done_msg "bibles.sqlite staged to $LEGACY_DIR"

# ── Optional codesign ──────────────────────────────────────────────────────
# If APPLE_DEVELOPER_ID is set (full identity string from `security
# find-identity -v -p codesigning`, e.g. "Developer ID Application: Acme
# (ABCD1234)"), sign the bundle. Without this, Gatekeeper still lets users
# run the app but they have to right-click → Open the first time.
# Notarization (xcrun notarytool submit) is a separate step deliberately
# left out of this script; add it once a real Apple Developer account is in
# play and the team is ready to manage notarization secrets.
if [[ -n "${APPLE_DEVELOPER_ID:-}" ]]; then
    step "Codesigning with identity: $APPLE_DEVELOPER_ID"
    codesign --force --deep --options runtime --timestamp \
        --sign "$APPLE_DEVELOPER_ID" "$APP_BUNDLE"
    codesign --verify --strict --verbose=2 "$APP_BUNDLE"
else
    warn 'APPLE_DEVELOPER_ID not set — producing an unsigned bundle. Users will see a Gatekeeper warning on first launch.'
fi

# ── ZIP ────────────────────────────────────────────────────────────────────
if [[ $SKIP_ZIP -eq 0 ]]; then
    ZIP_NAME="Crater-$VERSION-macos.zip"
    ZIP_PATH="$DIST_ROOT/$ZIP_NAME"
    rm -f "$ZIP_PATH"
    step "Creating $ZIP_NAME"
    # `ditto -c -k --keepParent` is the Apple-blessed way to zip a .app —
    # it preserves extended attributes, resource forks, and symlinks
    # (regular `zip` corrupts the Versions/Current chain inside Qt
    # frameworks, and the bundle then fails Gatekeeper validation).
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    done_msg "$ZIP_PATH"
fi

# ── DMG ────────────────────────────────────────────────────────────────────
if [[ $SKIP_DMG -eq 0 ]]; then
    DMG_NAME="Crater-$VERSION-macos.dmg"
    DMG_PATH="$DIST_ROOT/$DMG_NAME"
    rm -f "$DMG_PATH"
    step "Creating $DMG_NAME"
    # hdiutil layout: assemble the bundle plus a symlink to /Applications
    # in a staging dir, then create a UDZO (compressed) disk image of it.
    # User opens the DMG, drags crater.app onto the /Applications symlink.
    # If you ever want a custom background image + window layout, swap this
    # block for create-dmg (https://github.com/create-dmg/create-dmg).
    DMG_STAGE=$(mktemp -d)
    trap 'rm -rf "$DMG_STAGE"' EXIT
    cp -R "$APP_BUNDLE" "$DMG_STAGE/"
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create \
        -volname "Crater $VERSION" \
        -srcfolder "$DMG_STAGE" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    done_msg "$DMG_PATH"
fi

step 'Done.'
