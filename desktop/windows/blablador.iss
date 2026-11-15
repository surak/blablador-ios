; The Windows installer: Blablador-<version>-windows-setup.exe, built by .github/workflows/desktop.yml with Inno Setup.
; Installs for the user alone (no admin rights) in %LOCALAPPDATA%\Programs\Blablador, the folder docs/app.ps1 uses,
; with the app, bla, a Start menu entry and an uninstaller, and puts the folder on the user's PATH so `bla` works in
; a new terminal. Running a newer setup over an older one updates it; the key and chats live elsewhere and stay.
;
;   iscc /DVersion=3.12.3 /DSource=<folder with Blablador.exe and bla.exe> blablador.iss

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef Source
  #define Source "."
#endif

[Setup]
AppId={{6A1D2F3E-8B7C-4C61-9E0A-B1A8D0C2F7E5}
AppName=Blablador
AppVersion={#Version}
AppPublisher=Forschungszentrum Jülich
AppPublisherURL=https://surak.github.io/blablador-ios/
DefaultDirName={localappdata}\Programs\Blablador
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
ChangesEnvironment=yes
OutputBaseFilename=Blablador-{#Version}-windows-setup
SetupIconFile=blablador.ico
UninstallDisplayIcon={app}\Blablador.exe
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: desktopicon; Description: "Put Blablador on the Desktop"

[Files]
Source: "{#Source}\Blablador.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Source}\bla.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Blablador"; Filename: "{app}\Blablador.exe"
Name: "{userdesktop}\Blablador"; Filename: "{app}\Blablador.exe"; Tasks: desktopicon

[Registry]
; bla on the PATH, once.
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; \
  Check: NotOnPath(ExpandConstant('{app}'))

[Run]
Filename: "{app}\Blablador.exe"; Description: "Start Blablador"; Flags: nowait postinstall

[Code]
var
  KeyPage: TInputQueryWizardPage;

// The first page asks for the API key, so Blablador starts signed in. Empty is fine when updating: the saved key stays.
procedure InitializeWizard;
begin
  KeyPage := CreateInputQueryPage(wpWelcome, 'Your Blablador API key',
    'Paste your key, then click Next.',
    'No key yet? Make one at codebase.helmholtz.cloud: Preferences, Access tokens, Add new token, tick read_user, ' +
    'Create, and copy it. Updating Blablador? Leave this empty to keep the key you have.');
  KeyPage.Add('API key:', True);
end;

// Saved by `bla login`, into the Credential Manager entry the app reads; through a file, so it is never in a command line.
procedure SaveKey;
var
  Key, KeyFile: string;
  Code: Integer;
begin
  Key := Trim(KeyPage.Values[0]);
  if Key = '' then
    exit;
  KeyFile := ExpandConstant('{tmp}\key.txt');
  SaveStringToFile(KeyFile, Key, False);
  Exec(ExpandConstant('{cmd}'), '/c ""' + ExpandConstant('{app}\bla.exe') + '" login < "' + KeyFile + '""', '',
    SW_HIDE, ewWaitUntilTerminated, Code);
  DeleteFile(KeyFile);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SaveKey;
end;

function NotOnPath(Dir: string): Boolean;
var
  Path: string;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    Path := '';
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') = 0;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path, Dir: string;
  P: Integer;
begin
  if CurUninstallStep <> usPostUninstall then
    exit;
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
    exit;
  Dir := ExpandConstant('{app}');
  Path := ';' + Path + ';';
  P := Pos(';' + Uppercase(Dir) + ';', Uppercase(Path));
  if P > 0 then
  begin
    Delete(Path, P, Length(Dir) + 1);
    Path := Copy(Path, 2, Length(Path) - 2);
    RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Path);
  end;
end;
