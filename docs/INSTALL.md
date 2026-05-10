# Installing Qt and building Crater on Windows

First-time setup for a Windows 10/11 dev machine. End result: you can run
`crater.exe` from PowerShell and see the operator console window.

Total time: **~30–45 minutes**, mostly waiting for installers to download.
Disk space needed: **~12 GB** (most of it is the MSVC toolchain + Qt).

---

## 1. Install the C++ toolchain (MSVC 2022)

Qt on Windows needs a real Microsoft compiler. The smallest legal way to
get it is the **Visual Studio Build Tools** (free, no IDE).

1. Download the Build Tools installer:
   <https://visualstudio.microsoft.com/downloads/?q=build+tools>
   (scroll to "Tools for Visual Studio" → "Build Tools for Visual Studio 2022")
2. Run it. In the **Workloads** tab, check only **"Desktop development with C++"**.
3. On the right side under "Installation details", make sure these are
   ticked (most are by default):
   - MSVC v143 — VS 2022 C++ x64/x86 build tools (latest)
   - Windows 11 SDK (or Windows 10 SDK if you're on 10)
   - C++ CMake tools for Windows
4. Click **Install**. ~6 GB download.

Verify:
```powershell
# In a fresh PowerShell window — should print a path like
# C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.40.33807
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
```

---

## 2. Install Qt 6

Qt's online installer is the official path. You need a **free Qt Account**
(open-source license is fine for Crater since it's GPL-3.0).

1. Create a Qt Account: <https://login.qt.io/register>
2. Download the **Qt Online Installer for Windows**:
   <https://www.qt.io/download-qt-installer-oss>
3. Run it. Sign in with your Qt Account.
4. Choose **"I am an individual person not using Qt for any company"** when
   prompted (this confirms you're using the open-source license).
5. Pick install location. Default is `C:\Qt`. **Keep it** — the rest of
   this guide assumes it.
6. At the **Select Components** screen, expand **Qt → Qt 6.11.x** and
   tick **only** these:
   - **MSVC 2022 64-bit**  ← the compiler kit
   - **Qt Quick 3D**  *(optional — skip unless we add 3D later)*
   - **Qt 5 Compatibility Module**  *(skip)*
   - **Sources**  *(skip — saves ~2 GB)*

   Then under **Additional Libraries**, tick:
   - **Qt Multimedia**
   - **Qt WebSockets**

   Everything else under that Qt 6.x version can stay unchecked. Crater's
   other Qt dependencies (Core, Gui, Qml, Quick, QuickControls2, Sql) are
   bundled in the base MSVC kit automatically.
7. Skip the "Developer and Designer Tools" section — we'll use CMake from
   PATH and don't need Qt Creator (you can install it later if you want
   an IDE).
8. Accept the license, click **Install**. ~3–4 GB download.

After install, your Qt should live at something like:
`C:\Qt\6.11.0\msvc2022_64\`

---

## 3. Install CMake (if you don't already have it)

Quickest path with winget (built into Windows 11):

```powershell
winget install Kitware.CMake
```

Or download from <https://cmake.org/download/> and install the
"Windows x64 Installer" — make sure to tick **"Add CMake to the system
PATH"** during install.

Verify in a **new** PowerShell window:
```powershell
cmake --version    # should show 3.21+
```

---

## 4. Build Crater

Open PowerShell, `cd` to the `qt/` folder of this repo, and run:

```powershell
# From C:\Users\KINGSLEY\Documents\crater\qt
$env:CMAKE_PREFIX_PATH = "C:\Qt\6.11.0\msvc2022_64"   # adjust to your Qt version

cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release --parallel
```

First build takes **~2–3 minutes** (it's compiling Qt's MOC outputs and
QML type registrations). Subsequent builds are seconds.

Common error during configure: **"Could not find a package configuration
file provided by Qt6"**. That means `CMAKE_PREFIX_PATH` doesn't point at
your Qt install. Check the path — it should end in `msvc2022_64`, not
just the version number.

---

## 5. Run

```powershell
.\build\Release\crater.exe
```

You should see the Crater operator console open at 1440×900: dark canvas,
warm-gold brand mark in the top bar, pulsing red **ON AIR** pill on the
right, three-pane layout with library / schedule / output, and a status
bar at the bottom.

---

## 6. Optional: switch the GPU backend

Qt's RHI defaults to **Direct3D 11** on Windows. HD 4000 supports
D3D11 feature level 11.0, so this should "just work". To force a
different backend for testing:

```powershell
$env:QSG_RHI_BACKEND = "opengl"   # or "vulkan", "d3d12"
.\build\Release\crater.exe
```

To see which backend Qt actually picked:

```powershell
$env:QSG_INFO = "1"
.\build\Release\crater.exe
# Watch stderr for "QSG: Using QRhi with backend ..."
```

---

## 7. Iterating on QML

QML files are compiled into the binary, so editing them currently
requires a rebuild. Two ways to speed that up while designing:

**Option A — `qml` runtime (fastest iteration):**

```powershell
& "C:\Qt\6.11.0\msvc2022_64\bin\qml.exe" .\app\qml\Main.qml -I .\build\app
```

This launches the QML scene without recompiling the C++ — edits to QML
files reload instantly. You lose the C++ engine services (`crater-core`)
but for shell/visual work that's fine.

**Option B — full rebuild:**

```powershell
cmake --build build --config Release --target crater
.\build\Release\crater.exe
```

---

## 8. Troubleshooting

**"The application failed to start because no Qt platform plugin could be
initialized."**
The Qt DLLs aren't on PATH. Either run from a shell where you've added
`C:\Qt\6.11.0\msvc2022_64\bin` to PATH, or run `windeployqt` against your
exe to copy them next to it:
```powershell
& "C:\Qt\6.11.0\msvc2022_64\bin\windeployqt.exe" .\build\Release\crater.exe
```

**Window is black / nothing renders.**
Try forcing the OpenGL backend (`$env:QSG_RHI_BACKEND = "opengl"`). If
that works, your D3D11 driver is the culprit — update Intel Graphics
drivers from intel.com.

**Build fails with `MSB8020` / "PlatformToolset=v143".**
You installed Qt for a different MSVC version than your Build Tools.
Either install the matching Qt MSVC kit or install MSVC 2019 Build Tools
to match a Qt MSVC 2019 kit.

**`qmllint` warnings flood the build log.**
Those are advisory — the build still produces a working binary. We can
silence them per-file with `set_source_files_properties` or add a strict
mode later.
