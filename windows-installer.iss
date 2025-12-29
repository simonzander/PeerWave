; PeerWave Windows Installer Script
; Uses Inno Setup Compiler
; Download from: https://jrsoftware.org/isinfo.php

#define MyAppName "PeerWave"
#define MyAppVersion GetEnv("APP_VERSION")
#if MyAppVersion == ""
  #define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "PeerWave Project"
#define MyAppURL "https://github.com/simonzander/PeerWave"
#define MyAppExeName "peerwave_client.exe"
#define MyAppAssocName MyAppName + " File"
#define MyAppAssocExt ".peerwave"
#define MyAppAssocKey StringChange(MyAppAssocName, " ", "") + MyAppAssocExt

[Setup]
; NOTE: The value of AppId uniquely identifies this application.
AppId={{8F7A9B3C-2E4D-5F6A-7B8C-9D0E1F2A3B4C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
; Uncomment the following line to run in non administrative install mode (install for current user only.)
;PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=.
OutputBaseFilename=PeerWave-{#MyAppVersion}-windows-installer
SetupIconFile=installer-icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=dark
; Require Windows 10 or later
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
; User experience
DisableProgramGroupPage=yes
DisableWelcomePage=no
; Branding
WizardImageFile=installer-banner.bmp
WizardSmallImageFile=installer-small.bmp
WizardImageStretch=no
WizardImageBackColor=$181C21
; Uninstall info
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "quicklaunchicon"; Description: "{cm:CreateQuickLaunchIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked; OnlyBelowVersion: 6.1; Check: not IsAdminInstallMode

[Files]
Source: "client\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "client\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
; Start Menu
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
; Desktop Icon (optional, unchecked by default)
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
; Quick Launch (Windows 7 and older)
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: quicklaunchicon

[Registry]
; Register application for "Add/Remove Programs" - use appropriate root based on install mode
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}"; ValueType: string; ValueName: "DisplayName"; ValueData: "{#MyAppName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}"; ValueType: string; ValueName: "DisplayVersion"; ValueData: "{#MyAppVersion}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}"; ValueType: string; ValueName: "Publisher"; ValueData: "{#MyAppPublisher}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}"; ValueType: string; ValueName: "URLInfoAbout"; ValueData: "{#MyAppURL}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}"; ValueType: string; ValueName: "DisplayIcon"; ValueData: "{app}\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}"; ValueType: string; ValueName: "UninstallString"; ValueData: "{uninstallexe}"; Flags: uninsdeletekey

; Register URL protocol handler for peerwave:// links
Root: HKCU; Subkey: "Software\Classes\peerwave"; ValueType: string; ValueName: ""; ValueData: "URL:PeerWave Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\peerwave"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\peerwave\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\peerwave\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey

[Run]
; Option to launch application after installation
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up AppData on uninstall (optional - ask user?)
Type: filesandordirs; Name: "{localappdata}\{#MyAppName}"

[Code]
// Custom install page for cleanup options
var
  CleanupPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin

  // Create custom page for uninstall cleanup options
  CleanupPage := CreateInputOptionPage(wpWelcome,
    'Installation Options', 'Configure installation behavior',
    'Please specify how you want to handle existing data.',
    False, False);
  
  CleanupPage.Add('Preserve existing user data during reinstall');
  CleanupPage.Values[0] := True;  // Default: preserve data
end;

function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
  OldVersion: String;
begin
  Result := True;
  
  // Check if application is running
  if CheckForMutexes('{#MyAppName}Mutex') then
  begin
    if MsgBox('{#MyAppName} is currently running. Please close it before continuing.' + #13#10 + 'Do you want to close it now?',
              mbConfirmation, MB_YESNO) = IDYES then
    begin
      // Try to gracefully terminate the application
      // Note: This is a placeholder - actual implementation would need process management
      Result := True;
    end
    else
    begin
      Result := False;
    end;
  end;
  
  // Check for existing installation
  if RegQueryStringValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppName}',
     'DisplayVersion', OldVersion) then
  begin
    if CompareStr(OldVersion, '{#MyAppVersion}') <> 0 then
    begin
      if MsgBox('Version ' + OldVersion + ' is currently installed. Do you want to upgrade to version {#MyAppVersion}?',
                mbConfirmation, MB_YESNO) = IDNO then
      begin
        Result := False;
      end;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    AppDataDir := ExpandConstant('{localappdata}\{#MyAppName}');
    
    if DirExists(AppDataDir) then
    begin
      if MsgBox('Do you want to remove all user data (database, cache, logs)?' + #13#10 +
                'This cannot be undone.' + #13#10#13#10 +
                'Directory: ' + AppDataDir,
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(AppDataDir, True, True, True);
      end;
    end;
  end;
end;

[Messages]
; Custom messages
WelcomeLabel2=This will install [name/ver] on your computer.%n%nPeerWave is a decentralized peer-to-peer communication platform with end-to-end encryption.%n%nIt is recommended that you close all other applications before continuing.
FinishedLabel=Setup has finished installing [name] on your computer. The application may be launched by selecting the installed shortcuts.
