#!/usr/bin/env bash
# Build, deploy, and package Crater for Linux distribution.
#
# Linux twin of release.sh (macOS) and release.ps1 (Windows): same version
# parsing, same Bible-DB resolution order, same dist/ layout. Produces one
# self-contained Crater-<version>-x86_64.AppImage.
#
# Designed to run from a clean shell on a dev machine, and to be invoked
# verbatim by the GitHub Actions release workflow.
#
# Flags:
#   --qt-dir <path>          Qt Linux kit (gcc_64). Otherwise $QT_ROOT_DIR
#                            (set by install-qt-action), then the newest
#                            ~/Qt/<version>/gcc_64.
#   --version <X.Y.Z>        Overrides version parsed from CMakeLists.txt.
#                            CI passes the orchestrator's version here.
#   --skip-build             Skip cmake configure + build (iterate on packaging).
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
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qt-dir)     QT_DIR="$2"; shift 2 ;;
        --version)    VERSION_OVERRIDE="$2"; shift 2 ;;
        --config)     CONFIGURATION="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --clean)      CLEAN=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Same release build dir the other two drivers use; never collides with the
# dev tree's build/.
BUILD_DIR="$QT_ROOT/build-release"
DIST_ROOT="$QT_ROOT/dist"
APPDIR="$DIST_ROOT/AppDir"
PACKAGING_DIR="$QT_ROOT/packaging"
TOOLS_DIR="$BUILD_DIR/linuxdeploy"

# Bible DB: same fixed Release asset, same SHA-256 as the other drivers.
BIBLE_DB_PATH="$PACKAGING_DIR/bibles.sqlite"
BIBLE_DB_LOCAL_SOURCE="$QT_ROOT/../electron/src/assets/default/databases/bibles.sqlite"
BIBLE_DB_URL='https://github.com/vygr-labs/crater-v2/releases/download/data-v1/bibles.sqlite'
BIBLE_DB_SHA256='d86eed30ff7e28f213a06dcc7e6d7439ea3c851756f593a999b110247a7e044c'

# Strong's concordance databases, "name:sha256" pairs.
STRONGS_DB_LOCAL_DIR="$QT_ROOT/../electron/src/assets/default/databases"
STRONGS_DB_URL_BASE='https://github.com/vygr-labs/crater-v2/releases/download/data-v1'
STRONGS_DBS=(
    "strongs-dictionary.sqlite:27890d55e17f15c717509538cc246005600a99938e5f212aa82131a478c89a38"
    "strongs-bible.sqlite:8934fdf629865eca7d4d16cbe3ec29d913d03c6b2ef0ec4294484d73232cb2d4"
)

# linuxdeploy is pinned to a tagged build by SHA-256, like the DBs above.
# Its Qt plugin is not: the last tagged plugin build (1-alpha-20250213-1)
# predates its Qt 6 fixes for Wayland shell integration, network-information
# plugins and qmlimportscanner, so it comes from the rolling `continuous`
# release and its hash is logged instead of checked. Pin it the same way
# once a tag newer than 2026-08 ships.
LINUXDEPLOY_URL='https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage'
LINUXDEPLOY_SHA256='c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d'
LINUXDEPLOY_QT_URL='https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage'
LINUXDEPLOY_QT_SHA256=''

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# ── Resolve Qt ─────────────────────────────────────────────────────────────
# 1. --qt-dir wins.  2. $QT_ROOT_DIR (install-qt-action).  3. the Qt online
# installer's default root. bin/qmake is the sentinel because it is what
# linuxdeploy-plugin-qt asks for plugin, QML and translation paths.
resolve_qt_dir() {
    if [[ -n "$QT_DIR" ]]; then
        [[ -x "$QT_DIR/bin/qmake" ]] || {
            echo "Explicit --qt-dir missing bin/qmake: $QT_DIR" >&2; exit 1; }
        echo "$QT_DIR"; return
    fi
    if [[ -n "${QT_ROOT_DIR:-}" && -x "$QT_ROOT_DIR/bin/qmake" ]]; then
        echo "$QT_ROOT_DIR"; return
    fi
    if [[ -d "$HOME/Qt" ]]; then
        local newest
        newest=$(ls -1 "$HOME/Qt" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -t. -k1,1n -k2,2n -k3,3n -r | head -n1 || true)
        if [[ -n "$newest" && -x "$HOME/Qt/$newest/gcc_64/bin/qmake" ]]; then
            echo "$HOME/Qt/$newest/gcc_64"; return
        fi
    fi
    cat >&2 <<EOF
Could not locate a Qt Linux kit. Tried:
  --qt-dir parameter        (not supplied)
  \$QT_ROOT_DIR             ${QT_ROOT_DIR:-not set}
  \$HOME/Qt/<version>/gcc_64

Pass --qt-dir explicitly, e.g.:
  ./scripts/release-linux.sh --qt-dir \$HOME/Qt/6.11.1/gcc_64
EOF
    exit 1
}

# ── Version ────────────────────────────────────────────────────────────────
# `tr '\n' ' '` flattens the file so the multi-line project() call matches a
# single-line regex (see release.sh for the long version of this note).
CMAKE_VERSION=$(tr '\n' ' ' < "$QT_ROOT/CMakeLists.txt" \
    | sed -nE 's/.*project\(Crater[[:space:]]+VERSION[[:space:]]+([0-9.]+).*/\1/p')
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

# ── Clean ──────────────────────────────────────────────────────────────────
if [[ $CLEAN -eq 1 ]]; then
    step 'Cleaning build/ and dist/'
    rm -rf "$BUILD_DIR" "$DIST_ROOT"
fi

# ── Configure + build ──────────────────────────────────────────────────────
# Ninja Multi-Config for the same reasons as the other drivers: it honors
# CMAKE_<LANG>_COMPILER_LAUNCHER (sccache in CI) and keeps the
# `--config Release` semantics used everywhere else.
if [[ $SKIP_BUILD -eq 0 ]]; then
    step "Configuring CMake (Qt at $QT_DIR_RESOLVED)"
    export CMAKE_PREFIX_PATH="$QT_DIR_RESOLVED"
    if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
        step "Reusing existing cache in $BUILD_DIR"
        cmake -S "$QT_ROOT" -B "$BUILD_DIR"
    else
        cmake -S "$QT_ROOT" -B "$BUILD_DIR" -G 'Ninja Multi-Config'
    fi
    step "Building $CONFIGURATION"
    cmake --build "$BUILD_DIR" --config "$CONFIGURATION" --parallel
fi

# ── Stage the AppDir ───────────────────────────────────────────────────────
# `cmake --install` lays the executable out as AppDir/usr/bin/crater, the
# FHS shape linuxdeploy expects (install(TARGETS) in app/CMakeLists.txt).
step "Staging $APPDIR"
rm -rf "$APPDIR"
cmake --install "$BUILD_DIR" --config "$CONFIGURATION" --prefix "$APPDIR/usr"
[[ -x "$APPDIR/usr/bin/crater" ]] || {
    echo "cmake --install did not produce $APPDIR/usr/bin/crater" >&2; exit 1; }

# ── Stage Bible DB ─────────────────────────────────────────────────────────
# The importer (core/src/import/ElectronDataImporter.cpp) and StrongsService
# walk up from the executable looking for legacy/<db>. Inside the AppImage
# the executable is usr/bin/crater, so usr/bin/legacy/ is the hop-0 hit,
# the same layout Windows ships beside crater.exe.
LEGACY_DIR="$APPDIR/usr/bin/legacy"
mkdir -p "$LEGACY_DIR"

step 'Staging Bible database'
if [[ ! -f "$BIBLE_DB_PATH" ]]; then
    mkdir -p "$PACKAGING_DIR"
    if [[ -f "$BIBLE_DB_LOCAL_SOURCE" ]]; then
        step "Importing bibles.sqlite from sibling electron tree"
        cp "$BIBLE_DB_LOCAL_SOURCE" "$BIBLE_DB_PATH"
    else
        step "Downloading bibles.sqlite from $BIBLE_DB_URL"
        curl -fSL --retry 3 -o "$BIBLE_DB_PATH" "$BIBLE_DB_URL"
    fi
fi
ACTUAL_SHA=$(sha256_of "$BIBLE_DB_PATH")
if [[ "$ACTUAL_SHA" != "$BIBLE_DB_SHA256" ]]; then
    rm -f "$BIBLE_DB_PATH"
    echo "bibles.sqlite SHA-256 mismatch. Expected $BIBLE_DB_SHA256, got $ACTUAL_SHA. The cached/downloaded file has been removed; rerun to refetch." >&2
    exit 1
fi
cp "$BIBLE_DB_PATH" "$LEGACY_DIR/bibles.sqlite"
done_msg "bibles.sqlite staged to $LEGACY_DIR"

# ── Stage Strong's DBs ─────────────────────────────────────────────────────
step "Staging Strong's databases"
for entry in "${STRONGS_DBS[@]}"; do
    name="${entry%%:*}"
    want_sha="${entry##*:}"
    dst="$PACKAGING_DIR/$name"
    if [[ ! -f "$dst" ]]; then
        mkdir -p "$PACKAGING_DIR"
        if [[ -f "$STRONGS_DB_LOCAL_DIR/$name" ]]; then
            step "Importing $name from sibling electron tree"
            cp "$STRONGS_DB_LOCAL_DIR/$name" "$dst"
        else
            step "Downloading $name from $STRONGS_DB_URL_BASE/$name"
            curl -fSL --retry 3 -o "$dst" "$STRONGS_DB_URL_BASE/$name"
        fi
    fi
    actual_sha=$(sha256_of "$dst")
    if [[ "$actual_sha" != "$want_sha" ]]; then
        rm -f "$dst"
        echo "$name SHA-256 mismatch. Expected $want_sha, got $actual_sha. The cached/downloaded file has been removed; rerun to refetch." >&2
        exit 1
    fi
    cp "$dst" "$LEGACY_DIR/$name"
done
done_msg "Strong's databases staged to $LEGACY_DIR"

# ── Icon ───────────────────────────────────────────────────────────────────
# Lifted out of packaging/crater.ico rather than rendered from the SVG, so
# Linux shows the exact 256 px image Windows and the in-app window icon use
# and the three can never drift. The SVG colours itself with currentColor,
# which not every rasterizer resolves. The file name must match the
# desktop entry's Icon= key.
ICON_PATH="$BUILD_DIR/crater.png"
step 'Extracting 256 px icon from crater.ico'
python3 - "$PACKAGING_DIR/crater.ico" "$ICON_PATH" <<'PY'
import struct, sys
src, out = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
_, kind, count = struct.unpack_from('<HHH', data, 0)
if kind != 1:
    sys.exit(f'{src} is not an icon file')
best = None
for i in range(count):
    w, h, _, _, _, _, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * i)
    w = w or 256   # 0 in the directory means 256
    if best is None or w > best[0]:
        best = (w, size, offset)
w, size, offset = best
png = data[offset:offset + size]
if w != 256 or not png.startswith(b'\x89PNG\r\n\x1a\n'):
    sys.exit(f'{src} has no 256 px PNG entry (largest is {w} px)')
open(out, 'wb').write(png)
PY
done_msg "$ICON_PATH"

# ── Fetch linuxdeploy ──────────────────────────────────────────────────────
fetch_tool() {
    local name="$1" url="$2" want_sha="$3"
    local dst="$TOOLS_DIR/$name"
    if [[ ! -f "$dst" ]]; then
        step "Downloading $name"
        mkdir -p "$TOOLS_DIR"
        curl -fSL --retry 3 -o "$dst" "$url"
    fi
    local got_sha
    got_sha=$(sha256_of "$dst")
    if [[ -n "$want_sha" && "$got_sha" != "$want_sha" ]]; then
        rm -f "$dst"
        echo "$name SHA-256 mismatch. Expected $want_sha, got $got_sha. The file has been removed; rerun to refetch." >&2
        exit 1
    fi
    [[ -n "$want_sha" ]] || warn "$name is unpinned; this build used sha256 $got_sha"
    chmod +x "$dst"
}
fetch_tool linuxdeploy-x86_64.AppImage "$LINUXDEPLOY_URL" "$LINUXDEPLOY_SHA256"
fetch_tool linuxdeploy-plugin-qt-x86_64.AppImage "$LINUXDEPLOY_QT_URL" "$LINUXDEPLOY_QT_SHA256"

# ── linuxdeploy + AppImage ─────────────────────────────────────────────────
# linuxdeploy copies every shared library the executable needs into
# usr/lib (minus the host-provided ones on its excludelist: glibc, libGL,
# fontconfig and friends), then the Qt plugin adds platform plugins, the QML
# modules imported from app/qml, the FFmpeg multimedia backend and Qt's
# translations, and writes a qt.conf pointing Qt at them.
#
#   APPIMAGE_EXTRACT_AND_RUN  run the tool AppImages without FUSE, which CI
#                             runners and containers do not have.
#   EXTRA_PLATFORM_PLUGINS    xcb is always deployed. main.cpp prefers it,
#                             but falls back to Wayland on a session with no
#                             XWayland, so the Wayland plugins ship too; the
#                             Qt plugin adds their shell and decoration
#                             integrations when it sees them.
#   EXTRA_QT_MODULES          waylandcompositor is the Qt plugin's switch for
#                             the wayland-graphics-integration-client plugins,
#                             which hardware-accelerated Wayland needs.
#   NO_STRIP                  linuxdeploy's bundled strip predates the ELF
#                             sections newer toolchains emit and can fail on
#                             them; the Qt kit's libraries ship stripped and
#                             ours is a Release build, so there is little to
#                             gain.
step 'Running linuxdeploy'
export APPIMAGE_EXTRACT_AND_RUN=1
export QMAKE="$QT_DIR_RESOLVED/bin/qmake"
export LD_LIBRARY_PATH="$QT_DIR_RESOLVED/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QML_SOURCES_PATHS="$QT_ROOT/app/qml"
export NO_STRIP=1
wayland_plugins=()
for p in "$QT_DIR_RESOLVED/plugins/platforms/"libqwayland*.so; do
    if [[ -f "$p" ]]; then wayland_plugins+=("$(basename "$p")"); fi
done
if [[ ${#wayland_plugins[@]} -gt 0 ]]; then
    EXTRA_PLATFORM_PLUGINS=$(IFS=';'; echo "${wayland_plugins[*]}")
    export EXTRA_PLATFORM_PLUGINS
    export EXTRA_QT_MODULES='waylandcompositor'
    done_msg "Wayland platform plugins: $EXTRA_PLATFORM_PLUGINS"
else
    warn "No Wayland platform plugin in $QT_DIR_RESOLVED/plugins/platforms; the AppImage will be X11-only."
fi

APPIMAGE_NAME="Crater-$VERSION-x86_64.AppImage"
export OUTPUT="$APPIMAGE_NAME"
export LINUXDEPLOY_OUTPUT_VERSION="$VERSION"
rm -f "$DIST_ROOT/$APPIMAGE_NAME"
(
    # linuxdeploy writes the AppImage into the working directory, and finds
    # the Qt plugin next to itself or on PATH.
    cd "$DIST_ROOT"
    PATH="$TOOLS_DIR:$PATH" "$TOOLS_DIR/linuxdeploy-x86_64.AppImage" \
        --appdir "$APPDIR" \
        --executable "$APPDIR/usr/bin/crater" \
        --desktop-file "$PACKAGING_DIR/linux/crater.desktop" \
        --icon-file "$ICON_PATH" \
        --plugin qt \
        --output appimage
)
[[ -f "$DIST_ROOT/$APPIMAGE_NAME" ]] || {
    echo "linuxdeploy finished but $DIST_ROOT/$APPIMAGE_NAME is missing" >&2; exit 1; }
chmod +x "$DIST_ROOT/$APPIMAGE_NAME"
done_msg "$DIST_ROOT/$APPIMAGE_NAME"

step 'Done.'
