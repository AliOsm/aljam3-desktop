#ifndef AppVersion
  #error AppVersion must be supplied by bin/build-installer
#endif

[Setup]
AppId={{A247B4AC-B09F-45B2-A9C2-30364B6FA32A}
AppName={code:LocalizedAppName}
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
UninstallDisplayName={code:LocalizedAppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
Type: files; Name: "{autoprograms}\Aljam3.lnk"
Type: files; Name: "{autoprograms}\الجامع.lnk"
Type: files; Name: "{autodesktop}\Aljam3.lnk"
Type: files; Name: "{autodesktop}\الجامع.lnk"
; Replace app-managed resources on upgrade. Books are stored separately in LocalAppData\Aljam3.
Type: filesandordirs; Name: "{app}\resources"

[Files]
Source: "..\dist\Aljam3\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{code:LocalizedAppName}"; Filename: "{app}\Aljam3.exe"; IconFilename: "{app}\resources\app\assets\brand\aljam3.ico"
Name: "{autodesktop}\{code:LocalizedAppName}"; Filename: "{app}\Aljam3.exe"; IconFilename: "{app}\resources\app\assets\brand\aljam3.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Aljam3.exe"; Description: "{code:OpenAppLabel}"; Flags: nowait postinstall skipifsilent

[Code]
function GetUserDefaultUILanguage: Word;
  external 'GetUserDefaultUILanguage@kernel32.dll stdcall';

function LocalizedAppName(Param: String): String;
begin
  if (GetUserDefaultUILanguage and $3FF) = 1 then
    Result := 'الجامع'
  else
    Result := 'Aljam3';
end;

function OpenAppLabel(Param: String): String;
begin
  if (GetUserDefaultUILanguage and $3FF) = 1 then
    Result := 'فتح الجامع'
  else
    Result := 'Open Aljam3';
end;
