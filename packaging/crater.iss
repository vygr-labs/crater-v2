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
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{4D6E3F0E-9C2C-4F88-9C04-7A2B0A4A3B5E}}
AppName=Crater
AppVersion={#AppVersion}
AppVerName=Crater {#AppVersion}
AppPublisher=Voyager Labs
AppPublisherURL=https://crater.voyagerlabs.tech
AppSupportURL=https://crater.voyagerlabs.tech
AppUpdatesURL=https://crater.voyagerlabs.tech
DefaultDirName={autopf}\Crater
DefaultGroupName=Crater
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\crater.exe
UninstallDisplayName=Crater {#AppVersion}
OutputDir={#OutputDir}
OutputBaseFilename=Crater-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "{#StagingDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#VcRedist}"; DestDir: "{tmp}"; Flags: deleteafterinstall

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

[Icons]
Name: "{group}\Crater";           Filename: "{app}\crater.exe"
Name: "{group}\Uninstall Crater"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Crater";     Filename: "{app}\crater.exe"; Tasks: desktopicon

[Code]
function VCRedistNeedsInstall(): Boolean;
var
  version: Cardinal;
begin
  // VC++ 2015-2022 share a single redistributable. Major version is recorded
  // under HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64\Major.
  // 14 means VS2015+ already present; the redist installer itself is idempotent
  // either way, but skipping the call shaves a few seconds off the install.
  if RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Major', version) then
    Result := version < 14
  else
    Result := True;
end;
