; Per-user installer for the self-contained Windows build.
; Build: dotnet publish src/LimLink.Desktop -c Release -r win-x64 --self-contained true -o <dir>
;        ISCC.exe /DSourceDir=<dir> /DAppVersion=<version> installer\LimLink.iss
#ifndef SourceDir
  #define SourceDir "..\release\win-x64"
#endif
#ifndef AppVersion
  #define AppVersion "1.0.1"
#endif


[Setup]
AppId={{6F1C2A7E-4B7D-4E64-9C1B-1E2D7A0C5B11}
AppName=LimLink
AppVersion={#AppVersion}
AppPublisher=杭州浮点极限科技有限公司
DefaultDirName={localappdata}\Programs\LimLink
DefaultGroupName=LimLink
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputBaseFilename=LimLink-Setup-{#AppVersion}-x64
SetupIconFile=..\src\LimLink.Desktop\AppIcon.ico
UninstallDisplayIcon={app}\LimLink.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
#ifexist AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl"
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The AppUserModelID matches ToastService.AppId so notifications are attributed to LimLink.
Name: "{group}\LimLink"; Filename: "{app}\LimLink.exe"; AppUserModelID: "LimLink.Desktop"
Name: "{userdesktop}\LimLink"; Filename: "{app}\LimLink.exe"; AppUserModelID: "LimLink.Desktop"; Tasks: desktopicon

[Run]
Filename: "{app}\LimLink.exe"; Description: "{cm:LaunchProgram,LimLink}"; Flags: nowait postinstall skipifsilent
