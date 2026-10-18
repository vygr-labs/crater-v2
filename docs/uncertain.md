# What the codebase isn't sure of

Written for #129. Each item names where it lives, what nobody has confirmed, and how to settle it. Items that turned out to be real bugs have their own issues and are marked as such.

There are almost no TODO, FIXME or "not sure why" comments in Crater's own code (the ones a search finds are in the bundled `sqlite3.h`). The uncertainty sits in behaviour instead: settings that reach further than their label says, state kept in two places, and code paths that have only ever run on Windows.

## Settings

- **Reduce motion changes the audience screen.** `AppearanceSection.qml:243` describes it as "Disable hover and transition animations", a console preference. It also turns every output's transition into a cut (`ProjectionScene.qml:44,49`) and freezes animated gradient backgrounds on the projector (`NodeRenderer.qml:87`). With it on, Settings > Projection > Transitions has no effect, and nothing says why. Checked offscreen: the projector's lyric transition goes from crossfade/280 ms to cut/0. *Settle:* decide whether it is meant to touch the audience. If yes, say so in its description and on the Transitions page. If no, drop it from ProjectionScene and NodeRenderer.
- **Two CCLI switches.** Appearance's "Show CCLI badges" (`AppearanceSection.qml:234`, "Display copyright info next to songs") only adds the number to the library list (`SongsTab.qml:964`). The credit on the projected slide is the Song page's `showSongCcli` (`AppState.qml:302,338`). An operator turning on the first expecting the second sees nothing change on screen. *Settle:* rename the Appearance one ("Show CCLI numbers in the song list") or fold it into the Song page.
- **Render resolution is stored but not used.** `SettingsService.h:60-65`, issue #18. The row is already hidden. Listed so the stored key isn't mistaken for a working one.
- **Global settings are opened five different ways.** By name in `SettingsService.cpp:53`, `OutputService.cpp:153`, `UpdateService.cpp:113`, `NdiRenderer.cpp:351` and `StartupGuard.cpp:302`; default-constructed in `NdiService.cpp:366` and `WindowChrome.cpp:109,173`, which depends on `setOrganizationName` in `main.cpp:286` having run; and through `profile::openGlobalSettings()`. They reach the same store in a normal run. In test mode only the last one is redirected to an ini file, so a test that constructs SettingsService or OutputService would write the real registry. None does today. *Settle:* route every reader through `openGlobalSettings()`.
- **Hidden and reordered translations are shared by every profile.** Bug, #143.

## Who owns what

- **Clear and logo are kept twice.** `AppState.isClear` and `showLogo` (`AppState.qml:97-98`) shadow `ProjectionService.isClear` and `showLogo`. Every writer today goes through AppState (`AppState.qml:1647-1651,1681-1682`, `Main.qml:110`, `PreviewPanel.qml:801`), so they agree. But `ProjectionService::toggleLogo()` (`ProjectionService.cpp:165`) is invokable and unused, and anything that calls the service directly, like a phone remote, would leave the console's Logo and Clear buttons showing the wrong state. *Settle:* have AppState read the service's properties rather than keep its own.
- **The live schedule row after a single remove.** Bug, #142.
- **Song section kind is guessed and never read.** `SongService.cpp:43` and `EasyWorshipImporter.cpp:251` are two copies of the same label-to-kind guess. Anything starting "pre" becomes a pre-chorus ("Prayer", "Prelude"), and labels in other languages ("Coro", "Estrofa") become "other". The comment says the kind feeds "downstream styling", but nothing in `app/` or `core/` reads a section's kind. *Settle:* confirm it is unused and stop storing a guess, or share one function with tests before anything starts depending on it.

## Linux and macOS

Crater ships a Linux AppImage and the release workflow knows about a macOS disk image, but almost everything below has only run on Windows.

- **"Show output behind the console" off Windows.** The switch (`ProjectionSection.qml:239`) depends on `ProjectionLayering`, which does nothing outside Windows (`ProjectionLayering.cpp:234`). `ProjectionWindow.qml:174` still turns the mode on, so on Linux or macOS a fullscreen projector on the console's own screen has nothing keeping it underneath. *Settle:* try it on the AppImage. If it covers the console, hide the switch off Windows.
- **Media URLs are built by gluing `file:///` to a path** in about twenty places (`AppState.qml:128`, `MediaMonitor.qml:115,168,212,220`, `MediaBackgroundLoader.qml:80,123,173,203`, `MediaTab.qml:1013,1047,1399,1415`, `PreviewPanel.qml:103`, and others). A Linux or macOS path already starts with `/`, which gives `file:////home/...`. That only works because the OS reads `//home` as `/home`. MediaPlaybackService also keys clips by this exact string, so one place building the URL properly (with `Qt.url` or `QUrl::fromLocalFile`) would stop matching the rest. *Settle:* one helper for all of them, then play a video and a background on the AppImage.
- **Linux updates.** The release workflow publishes `Crater-<version>-x86_64.AppImage` (`release.yml:164,243`), but `platformAssetName` returns nothing outside Windows and macOS (`UpdateService.cpp:99`). Settings > Updates still offers "Download update", which then fails with "This release has no installer for your platform" (`UpdateService.cpp:334`). *Settle:* decide whether the AppImage updates itself. Until it does, show the release page instead of a Download button that always fails.
- **macOS has not been run.** Updates expect `Crater-<version>-macos.dmg` and install by opening it (`UpdateService.cpp:97,588`). NDI looks in `/usr/local/lib/libndi.dylib` (`NdiService.cpp:182`). *Settle:* one run on a Mac, or say macOS is unsupported for now.
- **Bringing the console forward.** Single-instance hand-off, window placement and restoring the console are Windows-only (`SingleInstance.cpp:77,107`, `WindowChrome.cpp:120,167`). The fallback is `raise()` plus `requestActivate()` (`SingleInstance.cpp:119`), which Wayland ignores when the request comes from another process. *Settle:* launch Crater twice on a Wayland desktop and see whether the console comes forward.
- **The EasyWorship import hint is a Windows path** on every platform (`ImportDialog.qml:162`).

## Placeholders

These are switches with no setting behind them. They are labelled, so nobody is misled, but each one is a promise with no issue tracking it.

- NDI "Include audio" (`NdiSection.qml:284`), marked Soon.
- Projection "Clear output when idle" (`ProjectionSection.qml:734`), marked Soon. Also listed in `docs/TODO.md`.
- The Remote Control page (`RemoteControlSection.qml:4-6,142`) says the phone remote "ships in v1.1". Crater is at 0.7, and the working "Cast to TV browser" switch sits on the same page above the disclaimer.

*Settle:* an issue for each, or remove them until they are built.
