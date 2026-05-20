<#
.SYNOPSIS
    Build, deploy, and package Crater for Windows distribution.

.DESCRIPTION
    One-stop release driver. Reads the project version from qt/CMakeLists.txt,
    invokes cmake to build Release, stages the exe with windeployqt for full
    Qt dependency bundling, then produces a portable ZIP and (if Inno Setup
    is installed) a Crater-Setup-X.Y.Z.exe installer that also bootstraps the
    Visual C++ Runtime.

    Designed to run from a clean PowerShell window on a dev machine, and to
    be invoked verbatim by the GitHub Actions release workflow.

.PARAMETER QtDir
    Path to the Qt MSVC kit (e.g. C:\Qt\6.11.0\msvc2022_64). Optional —
    if omitted, the script tries `$env:QT_ROOT_DIR` (set by the GitHub
    Actions install-qt-action) then scans C:\Qt\<version>\msvc*_64\ for the
    newest installed kit.

.PARAMETER Configuration
    CMake build configuration. Defaults to Release.

.PARAMETER VersionOverride
    If set, overrides the version parsed from qt/CMakeLists.txt. CI passes
    the git tag here (with the leading 'v' stripped) so the tag is the
    authoritative version for the artifacts.

.PARAMETER SkipBuild
    Skip the cmake configure + build step. Use when iterating on packaging.

.PARAMETER SkipInstaller
    Skip the Inno Setup compile. Produces ZIP only.

.PARAMETER SkipZip
    Skip the ZIP archive step. Produces installer only.

.PARAMETER Clean
    Wipe build/ and dist/ before starting.

.EXAMPLE
    .\qt\scripts\release.ps1 -QtDir C:\Qt\6.11.0\msvc2022_64

.EXAMPLE
    .\qt\scripts\release.ps1 -QtDir C:\Qt\6.11.0\msvc2022_64 -SkipInstaller -Clean
#>
[CmdletBinding()]
param(
    [string] $QtDir,

    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')]
    [string] $Configuration = 'Release',

    [string] $VersionOverride,

    [switch] $SkipBuild,
    [switch] $SkipInstaller,
    [switch] $SkipZip,
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step($msg) { Write-Host ">>> $msg" -ForegroundColor Cyan }
function Write-Done($msg) { Write-Host "    $msg" -ForegroundColor Green }

# Resolve a usable Qt MSVC kit:
#   1. explicit -QtDir wins
#   2. $env:QT_ROOT_DIR (jurplel/install-qt-action sets this on CI)
#   3. scan C:\Qt\<version>\msvc{2022,2019}_64\ — newest version first
function Resolve-QtDir {
    param([string] $Explicit)

    if ($Explicit) {
        if (-not (Test-Path $Explicit)) {
            throw "Explicit -QtDir does not exist: $Explicit"
        }
        return (Resolve-Path $Explicit).Path
    }

    if ($env:QT_ROOT_DIR -and (Test-Path (Join-Path $env:QT_ROOT_DIR 'bin\windeployqt.exe'))) {
        return $env:QT_ROOT_DIR
    }

    $qtRoot = 'C:\Qt'
    if (Test-Path $qtRoot) {
        $candidates = Get-ChildItem -Path $qtRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object @{ Expression = { [Version]$_.Name } } -Descending

        foreach ($versionDir in $candidates) {
            foreach ($kit in @('msvc2022_64', 'msvc2019_64')) {
                $kitPath = Join-Path $versionDir.FullName $kit
                if (Test-Path (Join-Path $kitPath 'bin\windeployqt.exe')) {
                    return $kitPath
                }
            }
        }
    }

    throw @"
Could not locate a Qt MSVC kit. Tried:
  - -QtDir parameter         (not supplied)
  - `$env:QT_ROOT_DIR        ($(if ($env:QT_ROOT_DIR) { $env:QT_ROOT_DIR } else { 'not set' }))
  - C:\Qt\<version>\msvc2022_64\ (and msvc2019_64)

Pass -QtDir explicitly, e.g.:
  .\scripts\release.ps1 -QtDir C:\Qt\6.11.0\msvc2022_64
"@
}

# ── Paths ──────────────────────────────────────────────────────────────────
$ScriptDir    = $PSScriptRoot
$QtRoot       = Resolve-Path (Join-Path $ScriptDir '..')
# Use a release-specific build directory so this script never collides with
# the developer's dev `build/` tree (which may be configured with Ninja or
# a Debug build type). gitignored via the `build-*/` pattern in qt/.gitignore.
$BuildDir     = Join-Path $QtRoot 'build-release'
$DistRoot     = Join-Path $QtRoot 'dist'
$AppStage     = Join-Path $DistRoot 'Crater'
$PackagingDir = Join-Path $QtRoot 'packaging'
$IssFile      = Join-Path $PackagingDir 'crater.iss'
$VcRedistPath = Join-Path $PackagingDir 'vc_redist.x64.exe'
$VcRedistUrl  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'

# ── Version ────────────────────────────────────────────────────────────────
$cmakeLists = Get-Content (Join-Path $QtRoot 'CMakeLists.txt') -Raw
if ($cmakeLists -notmatch 'project\(Crater\s+VERSION\s+([\d.]+)') {
    throw "Could not parse 'project(Crater VERSION ...)' from qt/CMakeLists.txt"
}
$CMakeVersion = $Matches[1]

$Version = if ($VersionOverride) { $VersionOverride } else { $CMakeVersion }

if ($VersionOverride -and ($VersionOverride -ne $CMakeVersion)) {
    Write-Warning "Version override ($VersionOverride) differs from CMakeLists ($CMakeVersion). Using override for artifact names; binary will still report $CMakeVersion."
}

Write-Step "Crater version: $Version"

# ── Qt validation ──────────────────────────────────────────────────────────
$QtDir = Resolve-QtDir -Explicit $QtDir
Write-Step "Qt kit: $QtDir"
$WindeployQt = Join-Path $QtDir 'bin\windeployqt.exe'
if (-not (Test-Path $WindeployQt)) {
    throw "windeployqt.exe not found at $WindeployQt"
}

# ── Clean ──────────────────────────────────────────────────────────────────
if ($Clean) {
    Write-Step 'Cleaning build/ and dist/'
    foreach ($p in @($BuildDir, $DistRoot)) {
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }
}

# ── Configure + build ──────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Step "Configuring CMake (Qt at $QtDir)"
    $env:CMAKE_PREFIX_PATH = $QtDir

    # On a fresh configure we pin the Visual Studio multi-config generator —
    # gives us reliable `--config Release` semantics and matches the layout
    # qt/app/CMakeLists.txt's post-build deploy steps were tuned against.
    # On reconfigure we omit -G/-A: CMake refuses to switch generators on an
    # existing cache, and silently reusing whatever the cache picked is the
    # right behavior if a user manually configured this tree differently.
    $cacheExists = Test-Path (Join-Path $BuildDir 'CMakeCache.txt')
    if ($cacheExists) {
        Write-Step "Reusing existing cache in $BuildDir"
        & cmake -S $QtRoot -B $BuildDir
    } else {
        & cmake -S $QtRoot -B $BuildDir -G 'Visual Studio 17 2022' -A x64
    }
    if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed' }

    Write-Step "Building $Configuration"
    & cmake --build $BuildDir --config $Configuration --parallel
    if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
}

# Locate the built exe. Visual Studio generator drops it under <build>/<config>/,
# but qt/app/CMakeLists.txt pins RUNTIME_OUTPUT_DIRECTORY to ${CMAKE_BINARY_DIR}
# so the actual artifact is at <build>/crater.exe. Check both.
$ExeCandidates = @(
    (Join-Path $BuildDir 'crater.exe'),
    (Join-Path $BuildDir "$Configuration\crater.exe")
)
$ExePath = $ExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ExePath) {
    throw "crater.exe not found. Looked in: $($ExeCandidates -join '; ')"
}
Write-Step "Built exe: $ExePath"

# ── Stage ──────────────────────────────────────────────────────────────────
Write-Step "Staging to $AppStage"
if (Test-Path $AppStage) { Remove-Item -Recurse -Force $AppStage }
New-Item -ItemType Directory -Force -Path $AppStage | Out-Null
Copy-Item $ExePath $AppStage

# ── windeployqt ────────────────────────────────────────────────────────────
# --qmldir lets windeployqt's import-scanner read our QML and ship only the
# QML modules we actually use. Without it we'd drop the entire Qt QML tree
# into the stage (~400MB instead of ~50MB).
Write-Step 'Running windeployqt'
$QmlDir = Join-Path $QtRoot 'app\qml'
& $WindeployQt `
    --release `
    --qmldir $QmlDir `
    --no-translations `
    --no-system-d3d-compiler `
    --no-opengl-sw `
    (Join-Path $AppStage 'crater.exe')
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed (exit $LASTEXITCODE)" }

# ── Stage data files ───────────────────────────────────────────────────────
# The Bible database is NOT embedded in crater.exe (77 MB — too large for a
# Qt resource; see ElectronDataImporter.h). The app's first-run importer
# looks for it at <exe>/legacy/bibles.sqlite. windeployqt knows nothing about
# it, so it must be staged explicitly here — before both the ZIP and the
# installer steps, since each packages everything under $AppStage. Without
# this, a clean install has no scripture data at all.
Write-Step 'Staging Bible database'
$BibleDbSource = Join-Path $QtRoot '..\electron\src\assets\default\databases\bibles.sqlite'
if (-not (Test-Path $BibleDbSource)) {
    throw "bibles.sqlite not found at $BibleDbSource — refusing to package an installer with no scripture data."
}
$LegacyStage = Join-Path $AppStage 'legacy'
New-Item -ItemType Directory -Force -Path $LegacyStage | Out-Null
Copy-Item $BibleDbSource (Join-Path $LegacyStage 'bibles.sqlite')
Write-Done "bibles.sqlite staged to $LegacyStage"

# ── VC++ redist ────────────────────────────────────────────────────────────
if (-not $SkipInstaller) {
    if (-not (Test-Path $VcRedistPath)) {
        Write-Step "Downloading vc_redist.x64.exe from $VcRedistUrl"
        New-Item -ItemType Directory -Force -Path $PackagingDir | Out-Null
        Invoke-WebRequest -Uri $VcRedistUrl -OutFile $VcRedistPath -UseBasicParsing
    } else {
        Write-Step 'Using cached vc_redist.x64.exe'
    }
}

# ── ZIP ────────────────────────────────────────────────────────────────────
if (-not $SkipZip) {
    $ZipName = "Crater-$Version-win64.zip"
    $ZipPath = Join-Path $DistRoot $ZipName
    if (Test-Path $ZipPath) { Remove-Item $ZipPath }
    Write-Step "Creating $ZipName"
    Compress-Archive -Path "$AppStage\*" -DestinationPath $ZipPath -CompressionLevel Optimal
    Write-Done "$ZipPath"
}

# ── Inno Setup ─────────────────────────────────────────────────────────────
if (-not $SkipInstaller) {
    $Iscc = (Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue).Source
    if (-not $Iscc) {
        $candidates = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
        )
        $Iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $Iscc) {
        Write-Warning 'Inno Setup not found; skipping installer. Install from https://jrsoftware.org/isinfo.php or pass -SkipInstaller to silence.'
    } else {
        Write-Step "Compiling installer with $Iscc"
        & $Iscc `
            "/DAppVersion=$Version" `
            "/DStagingDir=$AppStage" `
            "/DVcRedist=$VcRedistPath" `
            "/DOutputDir=$DistRoot" `
            $IssFile
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed (exit $LASTEXITCODE)" }
        Write-Done (Join-Path $DistRoot "Crater-Setup-$Version.exe")
    }
}

Write-Host ''
Write-Host '>>> Release artifacts in:' -ForegroundColor Cyan
Get-ChildItem $DistRoot -File | ForEach-Object {
    $sizeMB = [math]::Round($_.Length / 1MB, 1)
    Write-Host ("    {0,-40} {1,8} MB" -f $_.Name, $sizeMB)
}
