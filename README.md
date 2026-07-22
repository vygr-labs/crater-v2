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

Requirements: Qt **6.11+** (Core, Gui, Qml, Quick, QuickControls2, Sql,
Multimedia, WebSockets), CMake 3.21+, a C++20 compiler (MSVC 2022, Clang 14+,
or GCC 11+).

We pin to recent Qt deliberately — the QML compiler (`qmlsc`) and the RHI
backends have improved measurably each release, which matters on the weak
hardware Crater targets. See [`docs/INSTALL.md`](docs/INSTALL.md) for a
first-time Windows setup walkthrough.

```powershell
# From qt/
cmake -S . -B build -DCMAKE_PREFIX_PATH="C:/Qt/6.11.0/msvc2022_64"
cmake --build build --config Release
.\build\Release\crater.exe
```

On Linux/macOS, set `CMAKE_PREFIX_PATH` to your Qt install (e.g.
`~/Qt/6.11.0/gcc_64`) and use the standard `cmake --build build` flow.

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

The v1 engine and operator console are largely complete. This table tracks
the high-level state; the detailed remaining-work punch-list lives in
[`docs/TODO.md`](docs/TODO.md).

| Subsystem                          | Electron source                              | Qt status |
| ---------------------------------- | -------------------------------------------- | --------- |
| Bible DB + FTS                     | `electron/src/backend/database/bible-*.ts`   | Done |
| Song DB + FTS                      | `electron/src/backend/database/song*.ts`     | Done |
| Themes + editor + `.craterheme` v2 | `electron/src/backend/database/theme-*.ts`   | Done |
| Schedule (auto-save, saved sets)   | `electron/src/backend/main.ts` (file-backed) | Done |
| Media (image / video / PDF)        | `electron/src/backend/database/media*.ts`    | Done |
| Fonts (system + user import)       | —                                            | Done |
| Projection rendering + transitions | `electron/src/components/app/projection/`    | Done |
| Operator console                   | `electron/src/components/app/`               | Done |
| Multi-monitor detection + routing  | —                                            | Done |
| EasyWorship import                 | `electron/src/backend/scripts/`              | Done |
| NDI sender                         | `electron/src/backend/ndi/`                  | Working — on-demand mode + non-1080p canvas tuning pending |
| Strong's concordance + interlinear | `electron/src/backend/database/strongs-*.ts` | Done — packaging (ship DBs beside exe) pending |
| Song collections                   | —                                            | **Not started** (sidebar buttons are no-op stubs) |
| Multi-output (stage / dynamic)     | —                                            | v1.1 — registry done, no render window yet |
| Remote control server              | `electron/src/backend/remote/`               | v1.1 — preview UI only (view-only BrowserCast works) |
| Auto-update                        | —                                            | v1.1 — external release scripts only |
