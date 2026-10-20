#ifndef AppVersion
  #define AppVersion "1.1.0-alpha"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{1D817671-B739-4A9F-89F2-4E11830DE6F1}
AppName=GhostBox
AppVersion={#AppVersion}
AppPublisher=GhostBox
DefaultDirName={localappdata}\Programs\GhostBox
DefaultGroupName=GhostBox
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=GhostBox-Setup-x64
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\GhostBox.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительные ярлыки:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
Root: HKCU; Subkey: "Software\Classes\ghostbox"; ValueType: string; ValueName: ""; ValueData: "URL:GhostBox Link"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\ghostbox"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\ghostbox\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\GhostBox.exe,0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\ghostbox\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\GhostBox.exe"" ""%1"""; Flags: uninsdeletekey

[Icons]
Name: "{group}\GhostBox"; Filename: "{app}\GhostBox.exe"
Name: "{group}\Удалить GhostBox"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GhostBox"; Filename: "{app}\GhostBox.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\GhostBox.exe"; Description: "Запустить GhostBox"; Verb: "runas"; Flags: shellexec nowait postinstall skipifsilent
