<#
.SYNOPSIS
    Build, deploy, and package Crater for Windows distribution.

.DESCRIPTION
    One-stop release driver. Reads the project version from qt/CMakeLists.txt,
    invokes cmake to build Release, stages the exe with windeployqt for full
    Qt dependency bundling, then produces a portable ZIP and (if Inno Setup
    is installed) a Crater-Setup-X.Y.Z.exe installer that also bootstraps the
    Visual C++ Runtime.

    Finally, unless -SkipRelease is passed, it creates (or updates) a DRAFT
    GitHub release tagged vX.Y.Z via the `gh` CLI and attaches the ZIP and
    installer. "Draft" means GitHub does not create the git tag until a human
    clicks Publish, so running this locally never pollutes tags or main; a
    re-run clobbers the same draft's assets, so it is safe to invoke repeatedly.

    Designed to run from a clean PowerShell window on a dev machine, and to
    be invoked verbatim by the GitHub Actions release workflow. NOTE: CI runs
    it with -SkipRelease because the release.yml orchestrator owns release
    creation in automation (a single, build-gated, combined Win+Mac draft).

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

.PARAMETER SkipRelease
    Skip creating/updating the draft GitHub release. CI passes this so the
    release.yml orchestrator's gate-protected publish job stays the single
    authoritative release creator in automation.

.PARAMETER Repo
    OWNER/REPO target for the draft release. Optional - defaults to whatever
    `gh` auto-detects from the checkout's git remote (origin), which is
    correct in CI and from a normal clone. Pass explicitly to target a fork.

.PARAMETER Clean
    Wipe build/ and dist/ before starting.

.EXAMPLE
    .\qt\scripts\release.ps1 -QtDir C:\Qt\6.11.0\msvc2022_64

.EXAMPLE
    .\qt\scripts\release.ps1 -QtDir C:\Qt\6.11.0\msvc2022_64 -SkipInstaller -Clean

.EXAMPLE
    # Package locally without touching GitHub:
    .\qt\scripts\release.ps1 -SkipRelease
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
    [switch] $SkipRelease,
    [switch] $Clean,

    [string] $Repo
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

# Bible database: 74 MB SQLite blob too large to commit to git, too important
# to omit (an installer without scripture data is a non-product). We fetch it
# once from a fixed GitHub Release asset on this same repo and cache it under
# packaging/ — the workflow's actions/cache step keys on the file path, so
# subsequent CI runs skip the download entirely.
# The local sibling path (../electron/...) is checked first as a courtesy to
# the dev workflow on machines that still have the electron repo cloned.
$BibleDbPath        = Join-Path $PackagingDir 'bibles.sqlite'
$BibleDbLocalSource = Join-Path $QtRoot '..\electron\src\assets\default\databases\bibles.sqlite'
$BibleDbUrl         = 'https://github.com/vygr-labs/crater-v2/releases/download/data-v1/bibles.sqlite'
$BibleDbSha256      = 'd86eed30ff7e28f213a06dcc7e6d7439ea3c851756f593a999b110247a7e044c'

# Strong's concordance databases (dictionary lexicon + KJV-with-Strong's).
# Same fetch/cache/verify pipeline as the Bible DB above — StrongsService
# (core/src/StrongsService.cpp) looks for them at <exe>/legacy/ alongside
# bibles.sqlite. Two files, ~19 MB combined; also too large to commit.
$StrongsDbLocalDir = Join-Path $QtRoot '..\electron\src\assets\default\databases'
$StrongsDbUrlBase  = 'https://github.com/vygr-labs/crater-v2/releases/download/data-v1'
$StrongsDbs = @(
    @{ Name = 'strongs-dictionary.sqlite'; Sha256 = '27890d55e17f15c717509538cc246005600a99938e5f212aa82131a478c89a38' }
    @{ Name = 'strongs-bible.sqlite';      Sha256 = '8934fdf629865eca7d4d16cbe3ec29d913d03c6b2ef0ec4294484d73232cb2d4' }
)

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

    # On a fresh configure we pin the Ninja Multi-Config generator.
    #   - Compiler-launcher caching (sccache / ccache) only works with the
    #     Ninja or Makefile generators. The Visual Studio generator
    #     silently ignores CMAKE_<LANG>_COMPILER_LAUNCHER, so MSBuild-based
    #     builds cannot use sccache at all. On CI that is the difference
    #     between a full cold-build on every push and a sub-minute warm
    #     rebuild driven entirely by cache hits.
    #   - Multi-Config keeps `cmake --build --config Release` semantics, so
    #     the rest of this script and qt/app/CMakeLists.txt's per-config
    #     RUNTIME_OUTPUT_DIRECTORY_<CONFIG> pins behave identically to the
    #     previous Visual-Studio-generator setup.
    #   - cl.exe is set explicitly so CMake does not accidentally auto-pick
    #     gcc/MinGW if either is on PATH (GitHub windows runners ship
    #     MinGW; some dev machines have it too).
    # Prereq: the surrounding env must have cl.exe plus INCLUDE/LIB exported.
    # CI does this via ilammy/msvc-dev-cmd; locally, dot-source dev-shell.ps1
    # before invoking this script.
    # On reconfigure we omit -G: CMake refuses to switch generators on an
    # existing cache, and silently reusing whatever the cache picked is the
    # right behavior if a user manually configured this tree differently.
    $cacheExists = Test-Path (Join-Path $BuildDir 'CMakeCache.txt')
    if ($cacheExists) {
        Write-Step "Reusing existing cache in $BuildDir"
        & cmake -S $QtRoot -B $BuildDir
    } else {
        & cmake -S $QtRoot -B $BuildDir `
            -G 'Ninja Multi-Config' `
            -DCMAKE_C_COMPILER=cl `
            -DCMAKE_CXX_COMPILER=cl `
            -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded `
            -DCMAKE_POLICY_DEFAULT_CMP0141=NEW
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
# The Bible database is NOT embedded in crater.exe (77 MB, too large for a
# Qt resource; see ElectronDataImporter.h). The app's first-run importer
# looks for it at <exe>/legacy/bibles.sqlite. windeployqt knows nothing about
# it, so it must be staged explicitly here, before both the ZIP and the
# installer steps, since each packages everything under $AppStage. Without
# this, a clean install has no scripture data at all.
Write-Step 'Staging Bible database'
# Resolution order:
#   1. packaging/bibles.sqlite  -- the canonical CI-friendly location, cached
#      between workflow runs by actions/cache (same pattern as vc_redist).
#   2. ../electron/.../bibles.sqlite -- legacy dev-box layout where the
#      Electron tree sits as a sibling of the Qt tree. Promotes it into
#      packaging/ so subsequent runs don't depend on that layout.
#   3. Download from the data-v1 GitHub Release asset and verify SHA-256.
# All three converge on $BibleDbPath; staging copies from there.
if (-not (Test-Path $BibleDbPath)) {
    if (Test-Path $BibleDbLocalSource) {
        Write-Step "Importing bibles.sqlite from sibling electron tree"
        New-Item -ItemType Directory -Force -Path $PackagingDir | Out-Null
        Copy-Item $BibleDbLocalSource $BibleDbPath
    } else {
        Write-Step "Downloading bibles.sqlite from $BibleDbUrl"
        New-Item -ItemType Directory -Force -Path $PackagingDir | Out-Null
        Invoke-WebRequest -Uri $BibleDbUrl -OutFile $BibleDbPath -UseBasicParsing
    }
}
$actualSha = (Get-FileHash $BibleDbPath -Algorithm SHA256).Hash.ToLower()
if ($actualSha -ne $BibleDbSha256) {
    Remove-Item $BibleDbPath -Force
    throw "bibles.sqlite SHA-256 mismatch. Expected $BibleDbSha256, got $actualSha. The cached/downloaded file has been removed; rerun to refetch."
}
$LegacyStage = Join-Path $AppStage 'legacy'
New-Item -ItemType Directory -Force -Path $LegacyStage | Out-Null
Copy-Item $BibleDbPath (Join-Path $LegacyStage 'bibles.sqlite')
Write-Done "bibles.sqlite staged to $LegacyStage"

# Strong's databases — same three-tier resolution as the Bible DB above,
# staged into the same legacy/ dir. The loop keeps the two files DRY.
Write-Step "Staging Strong's databases"
foreach ($db in $StrongsDbs) {
    $dst = Join-Path $PackagingDir $db.Name
    if (-not (Test-Path $dst)) {
        $localSrc = Join-Path $StrongsDbLocalDir $db.Name
        if (Test-Path $localSrc) {
            Write-Step "Importing $($db.Name) from sibling electron tree"
            New-Item -ItemType Directory -Force -Path $PackagingDir | Out-Null
            Copy-Item $localSrc $dst
        } else {
            $url = "$StrongsDbUrlBase/$($db.Name)"
            Write-Step "Downloading $($db.Name) from $url"
            New-Item -ItemType Directory -Force -Path $PackagingDir | Out-Null
            Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing
        }
    }
    $sha = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    if ($sha -ne $db.Sha256) {
        Remove-Item $dst -Force
        throw "$($db.Name) SHA-256 mismatch. Expected $($db.Sha256), got $sha. The cached/downloaded file has been removed; rerun to refetch."
    }
    Copy-Item $dst (Join-Path $LegacyStage $db.Name)
}
Write-Done "Strong's databases staged to $LegacyStage"

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

# ── Draft GitHub release ─────────────────────────────────────────────────────
# Create (or update) a DRAFT release tagged v$Version and attach the Windows
# artifacts via the gh CLI. Draft means GitHub does NOT create the git tag
# until a human clicks Publish, so this never pollutes the tag namespace or
# main; re-running clobbers the same draft's assets, so it is safe to repeat.
#
# CI note: the GitHub Actions Windows build job passes -SkipRelease. The
# release.yml orchestrator's `publish` job is the single authoritative release
# creator and only runs once BOTH the Windows and macOS builds pass, so it
# attaches all four artifacts to one combined draft. If this script also
# created a release inside the build job it would fire before the tag exists
# and before macOS has built (leaving partial drafts) and race the
# orchestrator. Local/standalone runs DO create the draft - that is the point.
if ($SkipRelease) {
    Write-Step 'Skipping draft GitHub release (-SkipRelease)'
} else {
    $Tag = "v$Version"

    # Only attach the artifacts that were actually produced this run.
    $ReleaseAssets = @(
        (Join-Path $DistRoot "Crater-$Version-win64.zip"),
        (Join-Path $DistRoot "Crater-Setup-$Version.exe")
    ) | Where-Object { Test-Path $_ }

    $Gh = (Get-Command 'gh' -ErrorAction SilentlyContinue).Source

    if (-not $Gh) {
        Write-Warning 'GitHub CLI (gh) not found; skipping draft release. Install from https://cli.github.com/ or pass -SkipRelease to silence.'
    } elseif ($ReleaseAssets.Count -eq 0) {
        Write-Warning "No release artifacts found in $DistRoot (ZIP and installer both skipped?); skipping draft release."
    } else {
        # A logged-out dev box should not fail the whole packaging run, so
        # treat "not authenticated" as a skip rather than an error. The
        # try/catch guards PS 5.1's habit of turning a native command's
        # stderr write into a terminating error under $ErrorActionPreference.
        try { & $Gh auth status 2>$null | Out-Null } catch { }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "gh is not authenticated (run 'gh auth login'); skipping draft release."
        } else {
            $RepoArgs = if ($Repo) { @('--repo', $Repo) } else { @() }

            # `gh release view` finds a draft by tag name even before the git
            # tag is pushed, so this correctly detects an existing draft.
            try { & $Gh release view $Tag @RepoArgs 2>$null | Out-Null } catch { }
            $releaseExists = ($LASTEXITCODE -eq 0)

            if ($releaseExists) {
                Write-Step "Updating existing draft release $Tag"
                try { & $Gh release upload $Tag @ReleaseAssets @RepoArgs --clobber } catch { }
                if ($LASTEXITCODE -ne 0) { throw "gh release upload failed (exit $LASTEXITCODE)" }
            } else {
                Write-Step "Creating draft release $Tag"
                try {
                    & $Gh release create $Tag @ReleaseAssets @RepoArgs `
                        --draft `
                        --title "Crater $Tag" `
                        --generate-notes
                } catch { }
                if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }
            }
            Write-Done "Draft release $Tag ready ($($ReleaseAssets.Count) asset(s) attached)"
        }
    }
}

Write-Host ''
Write-Host '>>> Release artifacts in:' -ForegroundColor Cyan
Get-ChildItem $DistRoot -File | ForEach-Object {
    $sizeMB = [math]::Round($_.Length / 1MB, 1)
    Write-Host ("    {0,-40} {1,8} MB" -f $_.Name, $sizeMB)
}
