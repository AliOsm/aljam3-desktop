#ifndef AppVersion
  #error AppVersion must be supplied by bin/build-installer
#endif

[Setup]
AppId={{A247B4AC-B09F-45B2-A9C2-30364B6FA32A}
AppName=Aljam3
AppVersion={#AppVersion}
AppPublisher=Aljam3
AppPublisherURL=https://aljam3.com
DefaultDirName={localappdata}\Programs\Aljam3
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
OutputDir=..\dist
OutputBaseFilename=Aljam3-{#AppVersion}-windows-x64-setup
SetupIconFile=..\assets\brand\aljam3.ico
UninstallDisplayIcon={app}\resources\app\assets\brand\aljam3.ico
UninstallDisplayName=Aljam3
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Replace app-managed resources on upgrade. Books are stored separately in LocalAppData\Aljam3.
Type: filesandordirs; Name: "{app}\resources"

[Files]
Source: "..\dist\Aljam3\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Aljam3"; Filename: "{app}\Aljam3.exe"; IconFilename: "{app}\resources\app\assets\brand\aljam3.ico"
Name: "{autodesktop}\Aljam3"; Filename: "{app}\Aljam3.exe"; IconFilename: "{app}\resources\app\assets\brand\aljam3.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Aljam3.exe"; Description: "Open Aljam3"; Flags: nowait postinstall skipifsilent
