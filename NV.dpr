// Eduardo - 15/03/2026
program NV;

{$APPTYPE GUI}

{$R *.res}

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.ActiveX,
  Winapi.WebView2,
  Winapi.DwmApi,
  Winapi.ShellAPI;

const
  URL = 'https://conversa.igerp.com/';
  CLASS_NAME = 'TConversa';
  WINDOWN_TITLE = 'Conversa';
  WINDOWN_SIZE: TPoint = (X: 1920; Y: 1080);

  WM_TRAYICON       = WM_USER + 1;
  ID_TRAY_SHOW      = 1001;
  ID_TRAY_EXIT      = 1002;
  ID_TRAY_AUTOSTART = 1003;
  ID_TIMER_RETRY    = 2001;
  ID_TIMER_TIMEOUT  = 2002;
  NAVIGATION_TIMEOUT_MS = 30000;

  MUTEX_NAME    = 'NanoView.SingleInstance.'+ CLASS_NAME;
  SHOW_MSG_NAME = 'NanoView.ShowInstance.'+ CLASS_NAME;
  AUTORUN_KEY   = 'Software\Microsoft\Windows\CurrentVersion\Run';

  THEME_SCRIPT =
    '(function(){' +
    'function isDark(){' +
      'var t=localStorage.getItem("theme");' +
      'if(t==="dark"||t==="light")return t==="dark";' +
      'return window.matchMedia("(prefers-color-scheme: dark)").matches;' +
    '}' +
    'function notify(){try{window.chrome.webview.postMessage(isDark()?"dark":"light");}catch(e){}}' +
    'var _s=Storage.prototype.setItem;' +
    'Storage.prototype.setItem=function(k,v){var r=_s.apply(this,arguments);if(k==="theme")notify();return r;};' +
    'var _r=Storage.prototype.removeItem;' +
    'Storage.prototype.removeItem=function(k){var r=_r.apply(this,arguments);if(k==="theme")notify();return r;};' +
    'var _c=Storage.prototype.clear;' +
    'Storage.prototype.clear=function(){var r=_c.apply(this,arguments);notify();return r;};' +
    'window.addEventListener("storage",function(e){if(e.storageArea===localStorage&&(e.key==="theme"||e.key===null))notify();});' +
    'try{window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change",notify);}catch(e){}' +
    'if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",notify);' +
    'else notify();' +
    '})();';

var
  WebView: ICoreWebView2;
  Controller: ICoreWebView2Controller;
  MainWindow: HWND;
  TrayIcon: TNotifyIconData;
  TrayAdded: Boolean = False;
  WasMaximized: Boolean = False;
  SingleInstanceMutex: THandle = 0;
  WM_SHOW_INSTANCE: UINT = 0;
  UserDataFolder: string;
  PageLoaded: Boolean = False;
  NavigationRetries: Integer = 0;

function CreateCoreWebView2EnvironmentWithOptions(browserExecutableFolder: PWideChar; userDataFolder: PWideChar; environmentOptions: ICoreWebView2EnvironmentOptions; environmentCreatedHandler: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler): HRESULT; stdcall; external 'WebView2Loader.dll';

function SHGetFolderPathW(hwndOwner: HWND; nFolder: Integer; hToken: THandle; dwFlags: DWORD; pszPath: PWideChar): HRESULT; stdcall; external 'shell32.dll';
function ConvertSidToStringSidW(Sid: Pointer; var StringSid: PWideChar): BOOL; stdcall; external 'advapi32.dll';
function ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: PWideChar; StringSDRevision: DWORD; var SecurityDescriptor: Pointer; SecurityDescriptorSize: PDWORD): BOOL; stdcall; external 'advapi32.dll';
function GetSecurityDescriptorDacl(pSecurityDescriptor: Pointer; var lpbDaclPresent: BOOL; var pDacl: Pointer; var lpbDaclDefaulted: BOOL): BOOL; stdcall; external 'advapi32.dll';
function SetNamedSecurityInfoW(pObjectName: PWideChar; ObjectType: Integer; SecurityInfo: DWORD; psidOwner: Pointer; psidGroup: Pointer; pDacl: Pointer; pSacl: Pointer): DWORD; stdcall; external 'advapi32.dll';

const
  CSIDL_LOCAL_APPDATA                 = $001C;
  SE_FILE_OBJECT                      = 1;
  PROTECTED_DACL_SECURITY_INFORMATION = DWORD($80000000);
  SDDL_REVISION_1                     = 1;

type
  PTokenUserRec = ^TTokenUserRec;
  TTokenUserRec = record
    Sid: Pointer;
    Attributes: DWORD;
  end;

function DirExistsW(const Dir: string): Boolean;
var
  Attr: DWORD;
begin
  Attr := GetFileAttributesW(PWideChar(Dir));
  Result := (Attr <> INVALID_FILE_ATTRIBUTES) and ((Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0);
end;

function GetCurrentUserSidString: string;
var
  Token: THandle;
  Size: DWORD;
  Info: Pointer;
  SidStr: PWideChar;
begin
  Result := '';
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then Exit;
  try
    Size := 0;
    GetTokenInformation(Token, TokenUser, nil, 0, Size);
    if Size = 0 then Exit;
    GetMem(Info, Size);
    try
      if GetTokenInformation(Token, TokenUser, Info, Size, Size) then
        if ConvertSidToStringSidW(PTokenUserRec(Info).Sid, SidStr) then
        begin
          Result := string(SidStr);
          LocalFree(HLOCAL(SidStr));
        end;
    finally
      FreeMem(Info);
    end;
  finally
    CloseHandle(Token);
  end;
end;

function BuildUserDataFolder: string;
var
  Buf: array[0..MAX_PATH - 1] of WideChar;
begin
  Result := '';
  if SHGetFolderPathW(0, CSIDL_LOCAL_APPDATA, 0, 0, @Buf[0]) <> S_OK then Exit;
  Result := string(PWideChar(@Buf[0]));
  if (Result <> '') and (Result[Length(Result)] <> '\') then
    Result := Result + '\';
  Result := Result + CLASS_NAME;
end;

function EnsureSecureUserDataFolder(const Dir: string): Boolean;
var
  UserSid, Sddl: string;
  SD, Dacl: Pointer;
  DaclPresent, DaclDefaulted: BOOL;
  SA: TSecurityAttributes;
begin
  Result := False;
  if Dir = '' then Exit;

  SD := nil;
  UserSid := GetCurrentUserSidString;
  if UserSid <> '' then
  begin
    Sddl := 'D:P(A;OICI;FA;;;' + UserSid + ')(A;OICI;FA;;;SY)';
    if not ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(Sddl), SDDL_REVISION_1, SD, nil) then
      SD := nil;
  end;

  try
    if DirExistsW(Dir) then
      Result := True
    else
    begin
      if SD <> nil then
      begin
        SA.nLength := SizeOf(SA);
        SA.lpSecurityDescriptor := SD;
        SA.bInheritHandle := False;
        Result := CreateDirectoryW(PWideChar(Dir), @SA);
      end
      else
        Result := CreateDirectoryW(PWideChar(Dir), nil);
      if not Result then Exit;
    end;

    if (SD <> nil) and GetSecurityDescriptorDacl(SD, DaclPresent, Dacl, DaclDefaulted) and DaclPresent then
      SetNamedSecurityInfoW(PWideChar(Dir), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION or PROTECTED_DACL_SECURITY_INFORMATION,
        nil, nil, Dacl, nil);
  finally
    if SD <> nil then
      LocalFree(HLOCAL(SD));
  end;
end;

type
  TControllerHandler = class(TInterfacedObject, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)
  public
    function Invoke(errorCode: HRESULT; const createdController: ICoreWebView2Controller): HRESULT; stdcall;
  end;

  TEnvironmentHandler = class(TInterfacedObject, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
  public
    function Invoke(errorCode: HRESULT; const createdEnvironment: ICoreWebView2Environment): HRESULT; stdcall;
  end;

  TWebMessageReceivedHandler = class(TInterfacedObject, ICoreWebView2WebMessageReceivedEventHandler)
  public
    function Invoke(const sender: ICoreWebView2; const args: ICoreWebView2WebMessageReceivedEventArgs): HRESULT; stdcall;
  end;

  TPermissionRequestedHandler = class(TInterfacedObject, ICoreWebView2PermissionRequestedEventHandler)
  public
    function Invoke(const sender: ICoreWebView2; const args: ICoreWebView2PermissionRequestedEventArgs): HRESULT; stdcall;
  end;

  TNavigationCompletedHandler = class(TInterfacedObject, ICoreWebView2NavigationCompletedEventHandler)
  public
    function Invoke(const sender: ICoreWebView2; const args: ICoreWebView2NavigationCompletedEventArgs): HRESULT; stdcall;
  end;

procedure SetSizeWindow(Window: HWND; Ctrl: ICoreWebView2Controller; ZoomFactor: Double = 1);
var
  r: tagRECT;
  r2: TRect;
begin
  GetClientRect(Window, r2);
  r.left := r2.Left;
  r.top := r2.Top;
  r.right := r2.Right;
  r.bottom := r2.Bottom;
  Ctrl.SetBoundsAndZoomFactor(r, 1.0);
end;

procedure StartNavigate(Wnd: HWND);
begin
  if WebView = nil then Exit;
  KillTimer(Wnd, ID_TIMER_RETRY);
  KillTimer(Wnd, ID_TIMER_TIMEOUT);
  WebView.Navigate(URL);
  SetTimer(Wnd, ID_TIMER_TIMEOUT, NAVIGATION_TIMEOUT_MS, nil);
end;

function TControllerHandler.Invoke(errorCode: HRESULT; const createdController: ICoreWebView2Controller): HRESULT;
var
  Token: EventRegistrationToken;
begin
  if Failed(errorCode) or (createdController = nil) then
  begin
    Result := errorCode;
    Exit;
  end;

  Controller := createdController;
  Controller.Get_CoreWebView2(WebView);
  SetSizeWindow(MainWindow, Controller);

  WebView.add_WebMessageReceived(TWebMessageReceivedHandler.Create, Token);
  WebView.add_PermissionRequested(TPermissionRequestedHandler.Create, Token);
  WebView.add_NavigationCompleted(TNavigationCompletedHandler.Create, Token);
  WebView.AddScriptToExecuteOnDocumentCreated(PWideChar(string(THEME_SCRIPT)), nil);

  StartNavigate(MainWindow);

  SetProcessWorkingSetSize(GetCurrentProcess, SIZE_T(-1), SIZE_T(-1));

  Result := S_OK;
end;

function TEnvironmentHandler.Invoke(errorCode: HRESULT; const createdEnvironment: ICoreWebView2Environment): HRESULT;
begin
  if Failed(errorCode) or (createdEnvironment = nil) then
  begin
    Result := errorCode;
    Exit;
  end;
  createdEnvironment.CreateCoreWebView2Controller(MainWindow, TControllerHandler.Create);
  Result := S_OK;
end;

procedure ScheduleNavigationRetry(Wnd: HWND);
var
  Delay: DWORD;
begin
  case NavigationRetries of
    0: Delay :=  5000;
    1: Delay := 10000;
    2: Delay := 20000;
    3: Delay := 30000;
  else
    Delay := 60000;
  end;
  Inc(NavigationRetries);
  KillTimer(Wnd, ID_TIMER_RETRY);
  KillTimer(Wnd, ID_TIMER_TIMEOUT);
  SetTimer(Wnd, ID_TIMER_RETRY, Delay, nil);
end;

function TNavigationCompletedHandler.Invoke(const sender: ICoreWebView2; const args: ICoreWebView2NavigationCompletedEventArgs): HRESULT;
var
  Success: Integer;
begin
  Result := S_OK;
  if PageLoaded then Exit;

  Success := 0;
  if args <> nil then
    args.Get_IsSuccess(Success);

  if Success <> 0 then
  begin
    PageLoaded := True;
    NavigationRetries := 0;
    KillTimer(MainWindow, ID_TIMER_RETRY);
    KillTimer(MainWindow, ID_TIMER_TIMEOUT);
  end
  else
    ScheduleNavigationRetry(MainWindow);
end;

procedure SetDarkMode(Wnd: HWND; Enable: Boolean);
var
  Value: BOOL;
begin
  Value := Enable;
  DwmSetWindowAttribute(Wnd, DWMWA_USE_IMMERSIVE_DARK_MODE, @Value, SizeOf(Value));
end;

const
  PAM_ALLOW_DARK = 1;
type
  TSetPreferredAppMode    = function(AppMode: Integer): Integer; stdcall;
  TAllowDarkModeForWindow = function(Wnd: HWND; Allow: BOOL): BOOL; stdcall;
  TFlushMenuThemes        = procedure; stdcall;

var
  SetPreferredAppMode:    TSetPreferredAppMode    = nil;
  AllowDarkModeForWindow: TAllowDarkModeForWindow = nil;
  FlushMenuThemes:        TFlushMenuThemes        = nil;

procedure InitSystemDarkMenuSupport;
var
  UxTheme: HMODULE;
begin
  UxTheme := LoadLibrary('uxtheme.dll');
  if UxTheme = 0 then Exit;
  @SetPreferredAppMode    := GetProcAddress(UxTheme, MAKEINTRESOURCE(135));
  @AllowDarkModeForWindow := GetProcAddress(UxTheme, MAKEINTRESOURCE(133));
  @FlushMenuThemes        := GetProcAddress(UxTheme, MAKEINTRESOURCE(136));

  if Assigned(SetPreferredAppMode) then
    SetPreferredAppMode(PAM_ALLOW_DARK);
  if Assigned(FlushMenuThemes) then
    FlushMenuThemes;
end;

function TWebMessageReceivedHandler.Invoke(const sender: ICoreWebView2; const args: ICoreWebView2WebMessageReceivedEventArgs): HRESULT;
var
  Msg: PWideChar;
begin
  Msg := nil;
  if (args <> nil) and Succeeded(args.TryGetWebMessageAsString(Msg)) and (Msg <> nil) then
  begin
    SetDarkMode(MainWindow, string(Msg) = 'dark');
    CoTaskMemFree(Msg);
  end;
  Result := S_OK;
end;

function TPermissionRequestedHandler.Invoke(const sender: ICoreWebView2; const args: ICoreWebView2PermissionRequestedEventArgs): HRESULT;
begin
  if args <> nil then
    args.Set_State(COREWEBVIEW2_PERMISSION_STATE_ALLOW);
  Result := S_OK;
end;

procedure InitTrayIcon(Wnd: HWND);
begin
  ZeroMemory(@TrayIcon, SizeOf(TrayIcon));
  TrayIcon.cbSize           := SizeOf(TrayIcon);
  TrayIcon.Wnd              := Wnd;
  TrayIcon.uID              := 1;
  TrayIcon.uFlags           := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  TrayIcon.uCallbackMessage := WM_TRAYICON;
  TrayIcon.hIcon            := LoadIcon(HInstance, 'MAINICON');
  Move(PWideChar(WINDOWN_TITLE)^, TrayIcon.szTip[0], (Length(WINDOWN_TITLE) + 1) * SizeOf(WideChar));
end;

procedure ShowTrayIcon;
begin
  if not TrayAdded then
    TrayAdded := Shell_NotifyIcon(NIM_ADD, @TrayIcon);
end;

procedure RemoveTrayIcon;
begin
  if TrayAdded then
  begin
    Shell_NotifyIcon(NIM_DELETE, @TrayIcon);
    TrayAdded := False;
  end;
end;

procedure RestoreWindow(Wnd: HWND);
begin
  if WasMaximized then
    ShowWindow(Wnd, SW_SHOWMAXIMIZED)
  else
  if IsIconic(Wnd) then
    ShowWindow(Wnd, SW_RESTORE)
  else
    ShowWindow(Wnd, SW_SHOW);
  SetForegroundWindow(Wnd);

  if (not PageLoaded) and (WebView <> nil) then
  begin
    NavigationRetries := 0;
    StartNavigate(Wnd);
  end;
end;

function GetExePath: string;
var
  Buf: array[0..MAX_PATH - 1] of WideChar;
begin
  GetModuleFileName(0, Buf, MAX_PATH);
  Result := Buf;
end;

function IsAutoStartEnabled: Boolean;
var
  Key: HKEY;
begin
  Result := False;
  if RegOpenKeyEx(HKEY_CURRENT_USER, AUTORUN_KEY, 0, KEY_QUERY_VALUE, Key) = ERROR_SUCCESS then
  begin
    Result := RegQueryValueEx(Key, CLASS_NAME, nil, nil, nil, nil) = ERROR_SUCCESS;
    RegCloseKey(Key);
  end;
end;

procedure SetAutoStart(Enable: Boolean);
var
  Key: HKEY;
  Value: string;
begin
  if RegOpenKeyEx(HKEY_CURRENT_USER, AUTORUN_KEY, 0, KEY_SET_VALUE, Key) <> ERROR_SUCCESS then
    Exit;
  if Enable then
  begin
    Value := '"' + GetExePath + '" /tray';
    RegSetValueEx(Key, CLASS_NAME, 0, REG_SZ, PWideChar(Value), (Length(Value) + 1) * SizeOf(WideChar));
  end
  else
    RegDeleteValue(Key, CLASS_NAME);
  RegCloseKey(Key);
end;

procedure ShowTrayMenu(Wnd: HWND);
var
  Menu: HMENU;
  Pt: TPoint;
  AutoFlags: UINT;
begin
  Menu := CreatePopupMenu;
  AppendMenu(Menu, MF_STRING, ID_TRAY_SHOW, 'Abrir');

  AutoFlags := MF_STRING;
  if IsAutoStartEnabled then
    AutoFlags := AutoFlags or MF_CHECKED;
  AppendMenu(Menu, AutoFlags, ID_TRAY_AUTOSTART, 'Iniciar com o Windows');

  AppendMenu(Menu, MF_SEPARATOR, 0, nil);
  AppendMenu(Menu, MF_STRING, ID_TRAY_EXIT, 'Fechar');

  GetCursorPos(Pt);
  SetForegroundWindow(Wnd);
  TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.X, Pt.Y, 0, Wnd, nil);
  PostMessage(Wnd, WM_NULL, 0, 0);
  DestroyMenu(Menu);
end;

function WindowProc(hwnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  if (WM_SHOW_INSTANCE <> 0) and (msg = WM_SHOW_INSTANCE) then
  begin
    RestoreWindow(hwnd);
    Result := 0;
    Exit;
  end;

  case msg of
    WM_CREATE:
    begin
      MainWindow := hwnd;
      InitTrayIcon(hwnd);
      ShowTrayIcon;

      SetDarkMode(hwnd, True);
      if Assigned(AllowDarkModeForWindow) then
        AllowDarkModeForWindow(hwnd, True);

      UserDataFolder := BuildUserDataFolder;
      if (UserDataFolder <> '') and EnsureSecureUserDataFolder(UserDataFolder) then
        CreateCoreWebView2EnvironmentWithOptions(nil, PWideChar(UserDataFolder), nil, TEnvironmentHandler.Create)
      else
        CreateCoreWebView2EnvironmentWithOptions(nil, nil, nil, TEnvironmentHandler.Create);
      Result := 0;
      Exit;
    end;
    WM_SIZE:
    begin
      if Controller <> nil then
        SetSizeWindow(hwnd, Controller);
      Result := 0;
      Exit;
    end;
    WM_TIMER:
    begin
      if (wParam = ID_TIMER_RETRY) and not PageLoaded then
      begin
        KillTimer(hwnd, ID_TIMER_RETRY);
        StartNavigate(hwnd);
      end
      else if (wParam = ID_TIMER_TIMEOUT) and not PageLoaded then
      begin
        KillTimer(hwnd, ID_TIMER_TIMEOUT);
        ScheduleNavigationRetry(hwnd);
      end;
      Result := 0;
      Exit;
    end;
    WM_CLOSE:
    begin
      WasMaximized := IsZoomed(hwnd);
      ShowWindow(hwnd, SW_HIDE);
      ShowTrayIcon;
      Result := 0;
      Exit;
    end;
    WM_TRAYICON:
    begin
      case lParam of
        WM_LBUTTONUP, WM_LBUTTONDBLCLK: RestoreWindow(hwnd);
        WM_RBUTTONUP: ShowTrayMenu(hwnd);
      end;
      Result := 0;
      Exit;
    end;
    WM_COMMAND:
    begin
      case LOWORD(wParam) of
        ID_TRAY_SHOW:      RestoreWindow(hwnd);
        ID_TRAY_AUTOSTART: SetAutoStart(not IsAutoStartEnabled);
        ID_TRAY_EXIT:      DestroyWindow(hwnd);
      end;
      Result := 0;
      Exit;
    end;
    WM_DESTROY:
    begin
      RemoveTrayIcon;
      PostQuitMessage(0);
      Result := 0;
      Exit;
    end;
  end;
  Result := DefWindowProc(hwnd, msg, wParam, lParam);
end;

var
  Msg: TMsg;
  Wnd: HWND;
  wc: WNDCLASS;
  Existing: HWND;
  StartInTray: Boolean;
begin
  StartInTray := Pos('/tray', string(GetCommandLine)) > 0;

  WM_SHOW_INSTANCE := RegisterWindowMessage(SHOW_MSG_NAME);
  SingleInstanceMutex := CreateMutex(nil, False, MUTEX_NAME);
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    Existing := FindWindow(CLASS_NAME, nil);
    if Existing <> 0 then
      PostMessage(Existing, WM_SHOW_INSTANCE, 0, 0);
    if SingleInstanceMutex <> 0 then
      CloseHandle(SingleInstanceMutex);
    Exit;
  end;

  CoInitialize(nil);

  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

  InitSystemDarkMenuSupport;

  ZeroMemory(@wc, SizeOf(wc));
  wc.style := CS_HREDRAW or CS_VREDRAW;
  wc.lpfnWndProc := @WindowProc;
  wc.hInstance := HInstance;
  wc.hIcon := LoadIcon(HInstance, 'MAINICON');
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.hbrBackground := HBRUSH(COLOR_WINDOW + 1);
  wc.lpszClassName := CLASS_NAME;

  RegisterClass(wc);

  Wnd := CreateWindowEx(0, CLASS_NAME, WINDOWN_TITLE, WS_OVERLAPPEDWINDOW, Integer(CW_USEDEFAULT), Integer(CW_USEDEFAULT), WINDOWN_SIZE.X, WINDOWN_SIZE.Y, 0, 0, HInstance, nil);

  if StartInTray then
    WasMaximized := True
  else
  begin
    ShowWindow(Wnd, SW_SHOWMAXIMIZED);
    UpdateWindow(Wnd);
  end;

  while GetMessage(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;

  CoUninitialize;
end.
