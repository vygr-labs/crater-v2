# Crater (Qt port)

Qt 6 / QML rewrite of [Crater](../electron/) targeting low-end church laptops
(4 GB RAM, Intel HD 4000-class iGPUs). The Electron implementation lives at
`../electron/` and remains the reference for behavior during the port.

## Architecture

Two CMake targets:

- **`crater-core`** (`core/`) — headless static library. Owns SQLite (Bible,
  songs, themes, Strong's), FTS, NDI sender, and (later) the WebSocket
  remote server. No Qt GUI dependencies. Exposes services as `Q_OBJECT`s
  so QML can bind to them as singletons / models.
- **`crater`** (`app/`) — thin executable. Sets up the QML engine, registers
  windows (operator console, projection output, hidden NDI mirror), and
  links `Crater::Core`.

The split keeps the engine independently testable and lets us swap the UI
layer in the future without touching data code. See `BibleService` for the
canonical service pattern; `SongService`, `ThemeService`, `StrongsService`,
`ScheduleService`, `NdiService`, `RemoteService` will follow.

## Hardware target

- Windows 10/11, 4 GB RAM, Intel HD 4000 (Ivy Bridge-era) iGPU, spinning HDD.
- Qt RHI defaults to **D3D11** on Windows; HD 4000 supports feature
  level 11.0 so this is the right backend. To force a different backend
  during testing: `set QSG_RHI_BACKEND=opengl` (or `vulkan`).
- Memory budget for the operator + projection windows together: **<150 MB
  resident**. NDI sender adds ~30–50 MB on top.

## Building

Requirements: Qt **6.5+** (Core, Gui, Qml, Quick, QuickControls2, Sql,
Multimedia, WebSockets), CMake 3.21+, a C++20 compiler (MSVC 2022, Clang 14+,
or GCC 11+).

```powershell
# From qt/
cmake -S . -B build -DCMAKE_PREFIX_PATH="C:/Qt/6.7.0/msvc2022_64"
cmake --build build --config Release
.\build\app\Release\crater.exe
```

On Linux/macOS, set `CMAKE_PREFIX_PATH` to your Qt install (e.g.
`~/Qt/6.7.0/gcc_64`) and use the standard `cmake --build build` flow.

## Layout

```
qt/
├── CMakeLists.txt          # top-level project, finds Qt
├── core/
│   ├── CMakeLists.txt
│   ├── include/crater/     # public headers (BibleService.h, Version.h, ...)
│   └── src/                # implementations
└── app/
    ├── CMakeLists.txt
    ├── src/main.cpp        # QML engine bootstrap
    └── qml/Main.qml        # operator console window
```

## Porting status

| Subsystem               | Electron source                                | Qt status |
| ----------------------- | ---------------------------------------------- | --------- |
| Bible DB + FTS          | `electron/src/backend/database/bible-*.ts`     | Stub      |
| Song DB + FTS           | `electron/src/backend/database/song*.ts`       | Pending   |
| Strong's concordance    | `electron/src/backend/database/strongs-*.ts`   | Pending   |
| Themes                  | `electron/src/backend/database/theme-*.ts`     | Pending   |
| Schedule                | `electron/src/backend/main.ts` (file-backed)   | Pending   |
| Projection rendering    | `electron/src/components/app/projection/`      | Pending   |
| Operator console        | `electron/src/components/app/`                 | Pending   |
| NDI sender              | `electron/src/backend/ndi/`                    | Pending   |
| Remote control server   | `electron/src/backend/remote/`                 | Deferred to v1.1 |
