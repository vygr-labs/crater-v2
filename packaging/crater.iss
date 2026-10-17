; Crater installer (Inno Setup 6).
;
; All variable values come from qt/scripts/release.ps1 via /D defines —
; this file stays declarative so version drift between source-of-truth
; (qt/CMakeLists.txt) and the installer is impossible.
;
; AppId is a stable, app-identity GUID. Inno Setup uses it to recognise
; upgrades vs first installs — *never* change it after the first public
; release, or upgraded installs land in a new directory and orphan the old.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#ifndef StagingDir
  #define StagingDir "..\dist\Crater"
#endif
#ifndef VcRedist
  #define VcRedist "vc_redist.x64.exe"
#endif
; The bundled redist's own version (e.g. 14.51.36247.0), read at compile time,
; is what VCRedistNeedsInstall compares the installed runtime against.
#define VcRedistMajor 0
#define VcRedistMinor 0
#define VcRedistRev 0
#define VcRedistBuild 0
#expr GetVersionComponents(VcRedist, VcRedistMajor, VcRedistMinor, VcRedistRev, VcRedistBuild)
; The registry's Bld is the third part of the file version.
#define VcRedistBld VcRedistRev
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif
#define BrandFont "FunnelSans-VariableFont_wght.ttf"

[Setup]
AppId={{4D6E3F0E-9C2C-4F88-9C04-7A2B0A4A3B5E}}
AppName=Crater
AppVersion={#AppVersion}
AppVerName=Crater {#AppVersion}
AppPublisher=Voyager Labs
AppPublisherURL=https://getcrater.org
AppSupportURL=https://getcrater.org/docs
AppUpdatesURL=https://getcrater.org/download
DefaultDirName={autopf}\Crater
DefaultGroupName=Crater
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\crater.exe
; Setup.exe, its windows and the uninstaller carry the Crater icon.
SetupIconFile=crater.ico
UninstallDisplayName=Crater {#AppVersion}
OutputDir={#OutputDir}
OutputBaseFilename=Crater-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Dark, like the app, in Setup and Uninstall alike. Needs Inno Setup 6.6
; or later. The wizard images use the splash's motif: the logo's cyan disc
; with rings around it, drawn whole on the wizard's background colour. One
; file per display scale, 100% to 250%, so Setup picks a sharp one.
WizardStyle=modern dark
; The console's panel surface, so the pages match the images.
WizardBackColor=#18181b
DisableWelcomePage=no
WizardImageFile=installer\wizard-100.png,installer\wizard-125.png,installer\wizard-150.png,installer\wizard-175.png,installer\wizard-200.png,installer\wizard-225.png,installer\wizard-250.png
WizardSmallImageFile=installer\wizard-small-100.png,installer\wizard-small-125.png,installer\wizard-small-150.png,installer\wizard-small-175.png,installer\wizard-small-200.png,installer\wizard-small-225.png,installer\wizard-small-250.png
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[LangOptions]
; Funnel Sans, loaded for this process only by [Code] below.
DialogFontName=Funnel Sans
WelcomeFontName=Funnel Sans

[Messages]
; Shorter than the stock wording. Setup closes a running Crater itself
; (CloseApplications), so the advice to close other programs is dropped.
WelcomeLabel1=Welcome to Crater
WelcomeLabel2=This installs [name/ver] on your computer.
FinishedHeadingLabel=Crater is installed
FinishedLabel=[name/ver] is ready. You can open it from the Start menu.
FinishedLabelNoIcons=[name/ver] is ready.

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "{#StagingDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#VcRedist}"; DestDir: "{tmp}"; Flags: deleteafterinstall
; The app's font, for Setup's and Uninstall's own text (see [Code]). Setup
; extracts it to {tmp}. The copy in {app} is for the uninstaller, which
; cannot extract anything.
Source: "..\app\resources\fonts\{#BrandFont}"; Flags: dontcopy
Source: "..\app\resources\fonts\{#BrandFont}"; DestDir: "{app}"; Flags: ignoreversion

[Run]
; VC++ runtime bootstrap. Exit code 1638 means a newer version is already
; installed - treat as success so the install doesn't fail on machines that
; already have the redist. 3010 is "success, reboot required".
Filename: "{tmp}\vc_redist.x64.exe"; \
  Parameters: "/install /quiet /norestart"; \
  StatusMsg: "Installing Visual C++ Runtime..."; \
  Flags: waituntilterminated; \
  Check: VCRedistNeedsInstall

Filename: "{app}\crater.exe"; \
  Description: "Launch Crater"; \
  Flags: nowait postinstall skipifsilent

; Relaunch after an in-app update. UpdateService runs this installer with
; /SILENT (no wizard) plus /LAUNCH=1, and the operator expects Crater to come
; back on its own - the entry above is skipifsilent and deliberately will not
; fire on that run. runasoriginaluser matters: setup is elevated, and a plain
; child process would inherit admin, leaving Crater writing its AppData as the
; wrong user from then on.
Filename: "{app}\crater.exe"; \
  Flags: nowait postinstall runasoriginaluser; \
  Check: LaunchRequested

[Icons]
Name: "{group}\Crater";           Filename: "{app}\crater.exe"
Name: "{group}\Uninstall Crater"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Crater";     Filename: "{app}\crater.exe"; Tasks: desktopicon

[Code]
// Setup and Uninstall set their text in Funnel Sans, the app's font
// (DialogFontName in [LangOptions]). It is loaded for this process only
// (FR_PRIVATE), so nothing is installed into Windows, and unloaded at the
// end so the temp copy can be deleted. If it fails to load, Windows uses
// its nearest face instead.
const
  FR_PRIVATE = $10;

function AddFontResourceEx(FileName: String; Flags: Cardinal; Reserved: Cardinal): Integer;
  external 'AddFontResourceExW@gdi32.dll stdcall';
function RemoveFontResourceEx(FileName: String; Flags: Cardinal; Reserved: Cardinal): Integer;
  external 'RemoveFontResourceExW@gdi32.dll stdcall';

var
  BrandFontPath: String;

procedure LoadBrandFont(Path: String);
begin
  if AddFontResourceEx(Path, FR_PRIVATE, 0) > 0 then
    BrandFontPath := Path;
end;

procedure UnloadBrandFont();
begin
  if BrandFontPath <> '' then
    RemoveFontResourceEx(BrandFontPath, FR_PRIVATE, 0);
  BrandFontPath := '';
end;

function InitializeSetup(): Boolean;
begin
  ExtractTemporaryFile('{#BrandFont}');
  LoadBrandFont(ExpandConstant('{tmp}\{#BrandFont}'));
  Result := True;
end;

procedure DeinitializeSetup();
begin
  UnloadBrandFont();
end;

// From a temp copy, so the installed file is free to be deleted.
function InitializeUninstall(): Boolean;
var
  Copy: String;
begin
  Copy := ExpandConstant('{tmp}\{#BrandFont}');
  if FileCopy(ExpandConstant('{app}\{#BrandFont}'), Copy, False) then
    LoadBrandFont(Copy);
  Result := True;
end;

procedure DeinitializeUninstall();
begin
  UnloadBrandFont();
end;

function LaunchRequested(): Boolean;
begin
  // True only when the caller passed /LAUNCH=1. In-app updates set it; a
  // person running the installer by hand does not, and gets the ordinary
  // "Launch Crater" checkbox on the finish page instead.
  Result := ExpandConstant('{param:LAUNCH|0}') = '1';
end;

function VCRedistNeedsInstall(): Boolean;
var
  major, minor, bld: Cardinal;
  key: String;
begin
  // Every VC++ runtime since 2015 is version 14.x and records itself under
  // this key. This used to skip the redist whenever ANY 14.x was present,
  // so a PC holding a 2019-2023 runtime kept it, and Crater (built with a
  // newer toolset) crashed in msvcp140.dll before showing a window. Crater
  // now ships its runtime beside crater.exe, which is what it actually
  // loads; this keeps the system copy current too. Install when the
  // installed runtime is older than the one bundled with this installer.
  key := 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
  if not (RegQueryDWordValue(HKLM, key, 'Major', major)
          and RegQueryDWordValue(HKLM, key, 'Minor', minor)
          and RegQueryDWordValue(HKLM, key, 'Bld', bld)) then
  begin
    Result := True;
    exit;
  end;
  if major <> {#VcRedistMajor} then
    Result := major < {#VcRedistMajor}
  else if minor <> {#VcRedistMinor} then
    Result := minor < {#VcRedistMinor}
  else
    Result := bld < {#VcRedistBld};
end;
