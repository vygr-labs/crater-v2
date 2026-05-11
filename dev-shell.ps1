# dev-shell.ps1
#
# Dot-source this from any PowerShell window to set up an MSVC + Ninja +
# Qt build environment for the Crater Qt port:
#
#   . .\dev-shell.ps1
#   cmake --preset release
#   cmake --build --preset release-app
#
# What it does:
#   - Locates Visual Studio via vswhere (any edition / year you have).
#   - Imports VS's DevShell module - same machinery the Start-menu
#     "Developer PowerShell for VS 2022" uses. Sets cl.exe, link.exe,
#     libpath, Windows SDK headers, etc.
#   - Adds Qt's bundled Ninja to PATH so `cmake -G Ninja` works.
#   - Adds Qt's `bin/` to PATH so windeployqt + Qt DLLs are reachable.
#
# Tweak $_qt_root if your Qt install isn't at C:\Qt\6.11.0\msvc2022_64.
#
# Note: this file is intentionally pure ASCII so Windows PowerShell 5
# parses it correctly without a UTF-8 BOM.

$ErrorActionPreference = 'Stop'

$_qt_root  = 'C:\Qt\6.11.0\msvc2022_64'
$_qt_ninja = 'C:\Qt\Tools\Ninja'

# Visual Studio dev environment
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found at $vswhere. Install VS 2022 (any edition with the C++ workload)."
}
$vsPath = & $vswhere -latest -property installationPath
if (-not $vsPath -or -not (Test-Path $vsPath)) {
    throw "No Visual Studio installation found via vswhere."
}

$devShellModule = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -DevCmdArguments '-arch=x64 -host_arch=x64' -SkipAutomaticLocation | Out-Null

# Qt + Ninja on PATH
if (Test-Path $_qt_ninja) {
    $env:Path = "$_qt_ninja;$env:Path"
}
if (Test-Path "$_qt_root\bin") {
    $env:Path = "$_qt_root\bin;$env:Path"
}

# Help CMake find Qt without us repeating -DCMAKE_PREFIX_PATH everywhere.
$env:CMAKE_PREFIX_PATH = $_qt_root

Write-Host ""
Write-Host "Crater dev shell ready:" -ForegroundColor Green
Write-Host "  Visual Studio : $vsPath"
Write-Host "  Qt            : $_qt_root"
Write-Host "  Ninja         : $_qt_ninja"
Write-Host ""
Write-Host "Usage:" -ForegroundColor Cyan
Write-Host "  cmake --preset release              # configure (only after CMakeLists.txt changes)"
Write-Host "  cmake --build --preset release-app  # build only the crater app (fast)"
Write-Host "  cmake --build --preset release      # full build (crater-core + crater app)"
Write-Host "  .\build\crater.exe                  # run"
Write-Host ""
