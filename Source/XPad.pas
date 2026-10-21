unit XPad;
{ Виртуальный DirectInput-джойстик поверх XInput + эмуляция клавиатуры.

  - игра видит ОДИН "джойстик" (старые физические джойстики скрыты)
  - горячее подключение: устройство отдаётся всегда, а XInput-индекс ищется на лету
  - вибрация: DirectInput Force Feedback -> XInputSetState
  - каждая кнопка/направление геймпада назначается в ini ОДНОЙ целью:
      JOY1..JOY32 -> кнопка DirectInput-джойстика   (IsKey = False)
      имя клавиши -> клавиша клавиатуры через SendInput (IsKey = True)
  - XInput опрашивает отдельный поток: клавиши работают, даже если игра
    сама джойстик в этот момент не опрашивает }

interface

uses Windows, SysUtils, DI8Types, XInput, KeyEmu;

type
  TFakeDI8 = class(TInterfacedObject, IDirectInput8A)
  private
    FReal: IDirectInput8A;
  public
    constructor Create(ARealRaw: Pointer);
    destructor Destroy; override;
    function CreateDevice(const rguid: TGUID; out lplpDirectInputDevice: IDirectInputDevice8A; pUnkOuter: IUnknown): HResult; stdcall;
    function EnumDevices(dwDevType: DWORD; lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult; stdcall;
    function GetDeviceStatus(const rguidInstance: TGUID): HResult; stdcall;
    function RunControlPanel(hwndOwner: HWND; dwFlags: DWORD): HResult; stdcall;
    function Initialize(hinst: THandle; dwVersion: DWORD): HResult; stdcall;
    function FindDevice(const rguidClass: TGUID; ptszName: PAnsiChar; out pguidInstance: TGUID): HResult; stdcall;
    function EnumDevicesBySemantics(ptszUserName: PAnsiChar; lpdiActionFormat: Pointer; lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult; stdcall;
    function ConfigureDevices(lpdiCallback: Pointer; lpdiCDParams: Pointer; dwFlags: DWORD; pvRefData: Pointer): HResult; stdcall;
  end;

procedure XPadShutdown;

implementation

const
  QSIZE = 128;
  DI_INFINITE = $FFFFFFFF;

  // Источники (всё, что умеет "нажиматься" на геймпаде). Имена = ключи в [Buttons] ini.
  SRC_COUNT = 24;
  SrcNames: array[0..SRC_COUNT - 1] of string = (
    'A', 'B', 'X', 'Y', 'LB', 'RB', 'BACK', 'START', 'LS', 'RS', 'LT', 'RT',
    'UP', 'DOWN', 'LEFT', 'RIGHT',
    'LS-UP', 'LS-DOWN', 'LS-LEFT', 'LS-RIGHT',
    'RS-UP', 'RS-DOWN', 'RS-LEFT', 'RS-RIGHT');

type
  // Куда назначен источник
  TBind = record
    IsKey: Boolean;   // False = кнопка джойстика JOYn, True = клавиша клавиатуры
    Code: Integer;    // JOY: индекс кнопки 0..31; KEY: код клавиши (см. KeyEmu); -1 = не назначено
  end;

  TSrcArray = array[0..SRC_COUNT - 1] of Boolean;

  TConfig = record
    Debug: Boolean;
    AlwaysPresent: Boolean;   // отдавать джойстик игре даже если геймпад сейчас не подключён
    DeadZone: Integer;        // мёртвая зона стика (0..32767)
    TrigThresh: Integer;      // порог триггеров LT/RT как кнопок
    StickThresh: Integer;     // порог стика для LS-UP/LS-LEFT/... как кнопок
    DpadAxes: Boolean;        // дублировать крестовину на оси X/Y
    RumbleScale: Integer;     // множитель вибрации, %
    NumButtons: Integer;      // сколько кнопок сообщаем игре
    KeysFocusOnly: Boolean;   // слать клавиши только когда окно игры активно
  end;

var
  GCfg: TConfig;
  GBind: array[0..SRC_COUNT - 1] of TBind;
  GAnyKey: Boolean = False;    // есть ли хоть одно назначение на клавишу
  GCfgLoaded: Boolean = False;
  GIni: string;

  GIdx: Integer = -1;          // найденный рабочий XInput-индекс
  GLastScan: DWORD = 0;
  GWantL: Word = 0;
  GWantR: Word = 0;

  // снимок состояния геймпада, который обновляет поток опроса
  GCS: TRTLCriticalSection;
  GSnap: TXInputState;
  GSnapOk: Boolean = False;
  GThread: THandle = 0;
  GStop: Boolean = False;

type
  TXPadEffect = class(TInterfacedObject, IDirectInputEffect)
  private
    FGuid: TGUID;
    FMag: DWORD;
    FGain: DWORD;
    FDur: DWORD;
    FRunning: Boolean;
    FStart: DWORD;
    function Strength: Double;
  public
    constructor Create(const AGuid: TGUID);
    destructor Destroy; override;
    procedure Parse(peff: PDIEffect; Flags: DWORD);
    procedure Push;
    procedure Tick;
    function Initialize(hinst: THandle; dwVersion: DWORD; const rguid: TGUID): HResult; stdcall;
    function GetEffectGuid(var pguid: TGUID): HResult; stdcall;
    function GetParameters(peff: Pointer; dwFlags: DWORD): HResult; stdcall;
    function SetParameters(peff: Pointer; dwFlags: DWORD): HResult; stdcall;
    function Start(dwIterations: DWORD; dwFlags: DWORD): HResult; stdcall;
    function Stop: HResult; stdcall;
    function GetEffectStatus(var pdwFlags: DWORD): HResult; stdcall;
    function Download: HResult; stdcall;
    function Unload: HResult; stdcall;
    function Escape(pesc: Pointer): HResult; stdcall;
  end;

  TXPadDevice = class(TInterfacedObject, IDirectInputDevice8A)
  private
    FAcquired: Boolean;
    FFirst: Boolean;
    FMin: array[0..1] of LongInt;
    FMax: array[0..1] of LongInt;
    FPrevAxis: array[0..1] of LongInt;
    FPrevPov: DWORD;
    FPrevBtn: array[0..31] of Boolean;
    FQ: array[0..QSIZE - 1] of TDIDeviceObjectData;
    FQCount: Integer;
    FSeq: DWORD;
    procedure Push(Ofs, Data: DWORD);
    procedure Refresh;
    procedure Compute(var Axis0, Axis1: LongInt; var Pov: DWORD; var Btn: array of Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    function GetCapabilities(lpDIDevCaps: Pointer): HResult; stdcall;
    function EnumObjects(lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult; stdcall;
    function GetProperty(rguidProp: DWORD; pdiph: Pointer): HResult; stdcall;
    function SetProperty(rguidProp: DWORD; pdiph: Pointer): HResult; stdcall;
    function Acquire: HResult; stdcall;
    function Unacquire: HResult; stdcall;
    function GetDeviceState(cbData: DWORD; lpvData: Pointer): HResult; stdcall;
    function GetDeviceData(cbObjectData: DWORD; rgdod: Pointer; var pdwInOut: DWORD; dwFlags: DWORD): HResult; stdcall;
    function SetDataFormat(lpdf: Pointer): HResult; stdcall;
    function SetEventNotification(hEvent: THandle): HResult; stdcall;
    function SetCooperativeLevel(hwnd: HWND; dwFlags: DWORD): HResult; stdcall;
    function GetObjectInfo(pdidoi: Pointer; dwObj: DWORD; dwHow: DWORD): HResult; stdcall;
    function GetDeviceInfo(pdidi: Pointer): HResult; stdcall;
    function RunControlPanel(hwndOwner: HWND; dwFlags: DWORD): HResult; stdcall;
    function Initialize(hinst: THandle; dwVersion: DWORD; const rguid: TGUID): HResult; stdcall;
    function CreateEffect(const rguid: TGUID; lpeff: Pointer; out ppdeff: IDirectInputEffect; punkOuter: IUnknown): HResult; stdcall;
    function EnumEffects(lpCallback: Pointer; pvRef: Pointer; dwEffType: DWORD): HResult; stdcall;
    function GetEffectInfo(pdei: Pointer; const rguid: TGUID): HResult; stdcall;
    function GetForceFeedbackState(var pdwOut: DWORD): HResult; stdcall;
    function SendForceFeedbackCommand(dwFlags: DWORD): HResult; stdcall;
    function EnumCreatedEffectObjects(lpCallback: Pointer; pvRef: Pointer; fl: DWORD): HResult; stdcall;
    function Escape(pesc: Pointer): HResult; stdcall;
    function Poll: HResult; stdcall;
    function SendDeviceData(cbObjectData: DWORD; rgdod: Pointer; var pdwInOut: DWORD; fl: DWORD): HResult; stdcall;
    function EnumEffectsInFile(lpszFileName: PAnsiChar; pec: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult; stdcall;
    function WriteEffectToFile(lpszFileName: PAnsiChar; dwEntries: DWORD; pPeff: Pointer; dwFlags: DWORD): HResult; stdcall;
    function BuildActionMap(lpdiaf: Pointer; lpszUserName: PAnsiChar; dwFlags: DWORD): HResult; stdcall;
    function SetActionMap(lpdiActionFormat: Pointer; lptszUserName: PAnsiChar; dwFlags: DWORD): HResult; stdcall;
    function GetImageInfo(lpdiDevImageInfoHeader: Pointer): HResult; stdcall;
  end;

var
  GActive: TXPadEffect = nil;  // эффект, который сейчас рулит вибрацией

// ---------------------------------------------------------------- утилиты

function At(P: Pointer; Ofs: Integer): Pointer;
begin
  Result := Pointer(Integer(P) + Ofs);
end;

procedure Log(const S: string);
var
  F: TextFile;
begin
  if not GCfg.Debug then Exit;
  try
    AssignFile(F, GIni + '.log');
    if FileExists(GIni + '.log') then Append(F) else Rewrite(F);
    WriteLn(F, IntToStr(GetTickCount) + ' ' + S);
    CloseFile(F);
  except
  end;
end;

// "JOY5" -> кнопка джойстика №5 (IsKey=False, Code=4)
// "A", "ENTER", "NUMPAD7"... -> клавиша (IsKey=True, Code=VK)
// "NONE" / пусто / "-1" -> не назначено
procedure ParseBind(S: string; var B: TBind);
var
  N: Integer;
begin
  B.IsKey := False;
  B.Code := -1;
  S := UpperCase(Trim(S));
  if (S = '') or (S = 'NONE') or (S = '-1') then Exit;

  if Copy(S, 1, 3) = 'JOY' then begin
    N := StrToIntDef(Copy(S, 4, 10), 0);
    if (N >= 1) and (N <= 32) then B.Code := N - 1
    else Log('bad joystick button name: ' + S);
    Exit;
  end;

  N := KeyFromName(S);
  if N > 0 then begin
    B.IsKey := True;
    B.Code := N;
  end else
    Log('unknown key name: ' + S);
end;

function BindToStr(const B: TBind): string;
begin
  if B.Code < 0 then Result := 'NONE'
  else if B.IsKey then Result := 'KEY $' + IntToHex(B.Code, 3)
  else Result := 'JOY' + IntToStr(B.Code + 1);
end;

// Проценты из ini (0..99) -> "сырое" значение XInput (Max = 32767 для стиков, 255 для триггеров).
// 100% не допускаем: мёртвая зона на весь диапазон дала бы деление на ноль.
function PctToRaw(Pct, Max: Integer): Integer;
begin
  if Pct < 0 then Pct := 0;
  if Pct > 99 then Pct := 99;
  Result := (Pct * Max) div 100;
end;

procedure LoadConfig;
var
  Buf: array[0..MAX_PATH] of Char;
  i: Integer;
  P, Def: string;
  function RI(const Sec, Key: string; DefVal: Integer): Integer;
  begin
    Result := Integer(GetPrivateProfileInt(PChar(Sec), PChar(Key), DefVal, PChar(P)));
  end;
  function RS(const Sec, Key, DefVal: string): string;
  var
    B: array[0..127] of Char;
  begin
    GetPrivateProfileString(PChar(Sec), PChar(Key), PChar(DefVal), B, Length(B), PChar(P));
    Result := Trim(StrPas(B));
  end;
begin
  if GCfgLoaded then Exit;
  GCfgLoaded := True;
  GetModuleFileName(HInstance, Buf, MAX_PATH);
  GIni := ChangeFileExt(string(Buf), '');
  P := GIni + '.ini';
  GCfg.Debug := RI('XPad', 'Debug', 0) <> 0;
  GCfg.AlwaysPresent := RI('XPad', 'AlwaysPresent', 1) <> 0;
  // все три значения в ini задаются в процентах
  GCfg.DeadZone := PctToRaw(RI('XPad', 'DeadZone', 24), 32767);
  GCfg.TrigThresh := PctToRaw(RI('XPad', 'TriggerThreshold', 24), 255);
  GCfg.StickThresh := PctToRaw(RI('XPad', 'StickThreshold', 50), 32767);
  GCfg.DpadAxes := RI('XPad', 'DpadToAxes', 1) <> 0;
  GCfg.RumbleScale := RI('XPad', 'RumbleScale', 100);
  GCfg.KeysFocusOnly := RI('XPad', 'KeysOnlyInForeground', 1) <> 0;
  GCfg.NumButtons := RI('XPad', 'Buttons', 12);
  if GCfg.NumButtons < 1 then GCfg.NumButtons := 1;
  if GCfg.NumButtons > 32 then GCfg.NumButtons := 32;

  GAnyKey := False;
  for i := 0 to SRC_COUNT - 1 do begin
    // по умолчанию: A,B,X,... -> JOY1,JOY2,..., остальное выключено
    if i < 12 then Def := 'JOY' + IntToStr(i + 1) else Def := 'NONE';
    ParseBind(RS('Buttons', SrcNames[i], Def), GBind[i]);
    if GBind[i].IsKey then begin
      if GBind[i].Code > 0 then GAnyKey := True;
    end else if GBind[i].Code >= GCfg.NumButtons then
      GCfg.NumButtons := GBind[i].Code + 1;   // JOYn больше Buttons= : расширяем сами
    Log('bind ' + SrcNames[i] + ' = ' + BindToStr(GBind[i]));
  end;
  Log('config loaded: ' + P + ', keys=' + IntToStr(Ord(GAnyKey)) +
      ', buttons=' + IntToStr(GCfg.NumButtons) +
      ', deadzone=' + IntToStr(GCfg.DeadZone) + ', stick=' + IntToStr(GCfg.StickThresh) +
      ', trigger=' + IntToStr(GCfg.TrigThresh));
end;

// ------------------------------------------------------------ XInput

function PadRumbleRaw(L, R: Word): Boolean;
var
  V: TXInputVibration;
  Idx: Integer;
begin
  Result := False;
  Idx := GIdx;
  if Idx < 0 then Exit;
  FillChar(V, SizeOf(V), 0);
  // В XInput.pas поля TXInputVibration объявлены как Integer (по 4 байта), а в
  // настоящей XINPUT_VIBRATION два Word подряд. Функция читает только первые 4 байта,
  // поэтому оба мотора пакуем в первое поле (низкое слово - левый, высокое - правый).
  V.wLeftMotorSpeed := Integer(Cardinal(L) or (Cardinal(R) shl 16));
  V.wRightMotorSpeed := 0;
  Result := XInputSetState(Idx, V) = ERROR_SUCCESS;
end;

procedure PadRumble(L, R: Word);
begin
  GWantL := L;
  GWantR := R;
  PadRumbleRaw(L, R);
end;

// Опрос XInput: ВЫЗЫВАЕТ ТОЛЬКО ПОТОК ОПРОСА (или игра, если потока нет).
// Индекс найденного геймпада запоминается; при отвале ищем заново - не чаще раза
// в секунду, опрос пустых слотов XInput дорогой.
function PadPoll(var St: TXInputState): Boolean;
var
  i: Integer;
  Now_: DWORD;
begin
  Result := False;
  if GIdx >= 0 then begin
    if XInputGetState(GIdx, St) = ERROR_SUCCESS then begin
      Result := True;
      Exit;
    end;
    Log('pad ' + IntToStr(GIdx) + ' lost');
    GIdx := -1;
    GLastScan := GetTickCount;
    Exit;
  end;
  Now_ := GetTickCount;
  if (Now_ - GLastScan) < 1000 then Exit;
  GLastScan := Now_;
  for i := 0 to 3 do
    if XInputGetState(i, St) = ERROR_SUCCESS then begin
      GIdx := i;
      Result := True;
      Log('pad found at index ' + IntToStr(i));
      PadRumbleRaw(GWantL, GWantR);
      Break;
    end;
end;

// Последнее состояние геймпада из потока опроса
function PadSnapshot(var St: TXInputState): Boolean;
begin
  if GThread <> 0 then begin
    EnterCriticalSection(GCS);
    St := GSnap;
    Result := GSnapOk;
    LeaveCriticalSection(GCS);
  end else
    Result := PadPoll(St);
end;

function PadAnyConnected: Boolean;
var
  St: TXInputState;
  i: Integer;
begin
  Result := False;
  for i := 0 to 3 do
    if XInputGetState(i, St) = ERROR_SUCCESS then begin
      Result := True;
      Break;
    end;
end;

function Norm(V: SmallInt; DZ: Integer): Double;
var
  a: Integer;
begin
  a := Abs(Integer(V));
  if a <= DZ then Result := 0
  else begin
    Result := (a - DZ) / (32767 - DZ);
    if Result > 1 then Result := 1;
    if V < 0 then Result := -Result;
  end;
end;

// Что сейчас "нажато" на геймпаде - по всем источникам разом
procedure ComputeSources(const St: TXInputState; var Src: TSrcArray);
var
  w: Word;
  T: Integer;
begin
  w := St.Gamepad.wButtons;
  T := GCfg.StickThresh;
  Src[0] := (w and XINPUT_GAMEPAD_A) <> 0;
  Src[1] := (w and XINPUT_GAMEPAD_B) <> 0;
  Src[2] := (w and XINPUT_GAMEPAD_X) <> 0;
  Src[3] := (w and XINPUT_GAMEPAD_Y) <> 0;
  Src[4] := (w and XINPUT_GAMEPAD_LEFT_SHOULDER) <> 0;
  Src[5] := (w and XINPUT_GAMEPAD_RIGHT_SHOULDER) <> 0;
  Src[6] := (w and XINPUT_GAMEPAD_BACK) <> 0;
  Src[7] := (w and XINPUT_GAMEPAD_START) <> 0;
  Src[8] := (w and XINPUT_GAMEPAD_LEFT_THUMB) <> 0;
  Src[9] := (w and XINPUT_GAMEPAD_RIGHT_THUMB) <> 0;
  Src[10] := St.Gamepad.bLeftTrigger > GCfg.TrigThresh;
  Src[11] := St.Gamepad.bRightTrigger > GCfg.TrigThresh;
  Src[12] := (w and XINPUT_GAMEPAD_DPAD_UP) <> 0;
  Src[13] := (w and XINPUT_GAMEPAD_DPAD_DOWN) <> 0;
  Src[14] := (w and XINPUT_GAMEPAD_DPAD_LEFT) <> 0;
  Src[15] := (w and XINPUT_GAMEPAD_DPAD_RIGHT) <> 0;
  Src[16] := St.Gamepad.sThumbLY > T;     // LS-UP
  Src[17] := St.Gamepad.sThumbLY < -T;    // LS-DOWN
  Src[18] := St.Gamepad.sThumbLX < -T;    // LS-LEFT
  Src[19] := St.Gamepad.sThumbLX > T;     // LS-RIGHT
  Src[20] := St.Gamepad.sThumbRY > T;     // RS-UP
  Src[21] := St.Gamepad.sThumbRY < -T;    // RS-DOWN
  Src[22] := St.Gamepad.sThumbRX < -T;    // RS-LEFT
  Src[23] := St.Gamepad.sThumbRX > T;     // RS-RIGHT
end;

// Клавиатурная часть: считаем, какие клавиши должны быть нажаты, и отдаём в KeyEmu.
// KeysApply шлёт SendInput только при СМЕНЕ состояния (кэш внутри KeyEmu).
procedure KeysTick(const St: TXInputState; Connected: Boolean);
var
  Src: TSrcArray;
  Want: TKeyWant;
  i: Integer;
  Active: Boolean;
begin
  if not GAnyKey then Exit;
  Active := Connected;
  if Active and GCfg.KeysFocusOnly then Active := GameHasFocus;
  FillChar(Want, SizeOf(Want), 0);
  if Active then begin
    ComputeSources(St, Src);
    for i := 0 to SRC_COUNT - 1 do
      if GBind[i].IsKey and (GBind[i].Code > 0) and Src[i] then
        Want[GBind[i].Code] := True;   // несколько источников на одну клавишу - ИЛИ
  end;
  KeysApply(Want);   // нет геймпада / игра не в фокусе -> всё отпустится
end;

function PollProc(Param: Pointer): DWORD; stdcall;
var
  St: TXInputState;
  Ok: Boolean;
begin
  while not GStop do begin
    FillChar(St, SizeOf(St), 0);
    Ok := PadPoll(St);
    EnterCriticalSection(GCS);
    GSnap := St;
    GSnapOk := Ok;
    LeaveCriticalSection(GCS);
    KeysTick(St, Ok);
    Sleep(2);
  end;
  KeysReleaseAll;
  Result := 0;
end;

procedure EnsurePollThread;
var
  Id: DWORD;
begin
  if GThread <> 0 then Exit;
  GStop := False;
  IsMultiThread := True;   // менеджер памяти Delphi должен знать про второй поток
  GThread := CreateThread(nil, 0, @PollProc, nil, 0, Id);
  if GThread = 0 then Log('CreateThread failed - polling from game thread')
  else Log('poll thread started');
end;

procedure FillInstance(var I: TDIDeviceInstanceA);
begin
  FillChar(I, SizeOf(I), 0);
  I.dwSize := SizeOf(I);
  I.guidInstance := GUID_XPadInstance;
  I.guidProduct := GUID_XPadProduct;
  I.dwDevType := $00000204;  // DI8DEVTYPE_GAMEPAD | STANDARD
  StrPLCopy(I.tszInstanceName, 'XInput Gamepad', 259);
  StrPLCopy(I.tszProductName, 'Controller (XInput)', 259);
  I.wUsagePage := 1;
  I.wUsage := 5;
end;

procedure XPadShutdown;
begin
  // Поток не ждём: в DllMain WaitFor грозит дедлоком (loader lock).
  GStop := True;
  KeysReleaseAll;
  if GIdx >= 0 then PadRumbleRaw(0, 0);
end;

// ------------------------------------------------------------ TFakeDI8

constructor TFakeDI8.Create(ARealRaw: Pointer);
begin
  inherited Create;
  Pointer(FReal) := ARealRaw;  // забираем уже имеющуюся ссылку без AddRef
  LoadConfig;
  EnsurePollThread;
  Log('IDirectInput8 wrapped');
end;

destructor TFakeDI8.Destroy;
begin
  FReal := nil;
  inherited;
end;

function TFakeDI8.CreateDevice(const rguid: TGUID; out lplpDirectInputDevice: IDirectInputDevice8A; pUnkOuter: IUnknown): HResult;
begin
  if SameGuid(rguid, GUID_XPadInstance) then begin
    lplpDirectInputDevice := TXPadDevice.Create;
    Log('CreateDevice: XPad');
    Result := DI_OK;
  end else
    Result := FReal.CreateDevice(rguid, lplpDirectInputDevice, pUnkOuter);
end;

function TFakeDI8.EnumDevices(dwDevType: DWORD; lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult;
var
  Inst: TDIDeviceInstanceA;
begin
  if dwDevType = DI8DEVCLASS_GAMECTRL then begin
    // старые джойстики не показываем вообще - только наш виртуальный
    Result := DI_OK;
    if GCfg.AlwaysPresent or PadAnyConnected then begin
      FillInstance(Inst);
      Log('EnumDevices(GAMECTRL): report XPad');
      TDIEnumDevicesCallbackA(lpCallback)(@Inst, pvRef);
    end else
      Log('EnumDevices(GAMECTRL): no pad, nothing reported');
  end else
    Result := FReal.EnumDevices(dwDevType, lpCallback, pvRef, dwFlags);
end;

function TFakeDI8.GetDeviceStatus(const rguidInstance: TGUID): HResult;
begin
  if SameGuid(rguidInstance, GUID_XPadInstance) then Result := DI_OK
  else Result := FReal.GetDeviceStatus(rguidInstance);
end;

function TFakeDI8.RunControlPanel(hwndOwner: HWND; dwFlags: DWORD): HResult;
begin
  Result := FReal.RunControlPanel(hwndOwner, dwFlags);
end;

function TFakeDI8.Initialize(hinst: THandle; dwVersion: DWORD): HResult;
begin
  Result := FReal.Initialize(hinst, dwVersion);
end;

function TFakeDI8.FindDevice(const rguidClass: TGUID; ptszName: PAnsiChar; out pguidInstance: TGUID): HResult;
begin
  Result := FReal.FindDevice(rguidClass, ptszName, pguidInstance);
end;

function TFakeDI8.EnumDevicesBySemantics(ptszUserName: PAnsiChar; lpdiActionFormat: Pointer; lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult;
begin
  Result := FReal.EnumDevicesBySemantics(ptszUserName, lpdiActionFormat, lpCallback, pvRef, dwFlags);
end;

function TFakeDI8.ConfigureDevices(lpdiCallback: Pointer; lpdiCDParams: Pointer; dwFlags: DWORD; pvRefData: Pointer): HResult;
begin
  Result := FReal.ConfigureDevices(lpdiCallback, lpdiCDParams, dwFlags, pvRefData);
end;

// ---------------------------------------------------------- TXPadEffect

constructor TXPadEffect.Create(const AGuid: TGUID);
begin
  inherited Create;
  FGuid := AGuid;
  FGain := 10000;
  FDur := DI_INFINITE;
end;

destructor TXPadEffect.Destroy;
begin
  if GActive = Self then begin
    GActive := nil;
    PadRumble(0, 0);
  end;
  inherited;
end;

function TXPadEffect.Strength: Double;
begin
  Result := (FMag / 10000) * (FGain / 10000) * (GCfg.RumbleScale / 100);
  if Result > 1 then Result := 1;
  if Result < 0 then Result := 0;
end;

procedure TXPadEffect.Push;
var
  v: Word;
begin
  if FRunning then v := Word(Round(Strength * 65535)) else v := 0;
  PadRumble(v, v);
end;

procedure TXPadEffect.Tick;
begin
  if FRunning and (FDur <> DI_INFINITE) and ((GetTickCount - FStart) > (FDur div 1000)) then begin
    FRunning := False;
    PadRumble(0, 0);
  end;
end;

procedure TXPadEffect.Parse(peff: PDIEffect; Flags: DWORD);
begin
  if (peff = nil) or (peff^.dwSize < $34) then Exit;
  if (Flags and DIEP_DURATION) <> 0 then FDur := peff^.dwDuration;
  if (Flags and DIEP_GAIN) <> 0 then FGain := peff^.dwGain;
  if ((Flags and DIEP_TYPESPECIFICPARAMS) <> 0) and (peff^.lpvTypeSpecificParams <> nil)
     and (peff^.cbTypeSpecificParams >= 4) then begin
    // у Periodic первое поле dwMagnitude, у ConstantForce - lMagnitude
    FMag := DWORD(Abs(PLongInt(peff^.lpvTypeSpecificParams)^));
    if FMag > 10000 then FMag := 10000;
  end;
  if FRunning and (GActive = Self) then Push;
end;

function TXPadEffect.Initialize(hinst: THandle; dwVersion: DWORD; const rguid: TGUID): HResult;
begin
  Result := DI_OK;
end;

function TXPadEffect.GetEffectGuid(var pguid: TGUID): HResult;
begin
  pguid := FGuid;
  Result := DI_OK;
end;

function TXPadEffect.GetParameters(peff: Pointer; dwFlags: DWORD): HResult;
begin
  Result := DI_OK;
end;

function TXPadEffect.SetParameters(peff: Pointer; dwFlags: DWORD): HResult;
begin
  Parse(PDIEffect(peff), dwFlags);
  if (dwFlags and DIEP_START) <> 0 then Start(1, 0);
  Result := DI_OK;
end;

function TXPadEffect.Start(dwIterations: DWORD; dwFlags: DWORD): HResult;
begin
  if (GActive <> nil) and (GActive <> Self) then GActive.FRunning := False;
  GActive := Self;
  FRunning := True;
  FStart := GetTickCount;
  Push;
  Result := DI_OK;
end;

function TXPadEffect.Stop: HResult;
begin
  FRunning := False;
  if GActive = Self then PadRumble(0, 0);
  Result := DI_OK;
end;

function TXPadEffect.GetEffectStatus(var pdwFlags: DWORD): HResult;
begin
  if FRunning then pdwFlags := 1 else pdwFlags := 0;
  Result := DI_OK;
end;

function TXPadEffect.Download: HResult;
begin
  Result := DI_OK;
end;

function TXPadEffect.Unload: HResult;
begin
  Result := DI_OK;
end;

function TXPadEffect.Escape(pesc: Pointer): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

// ---------------------------------------------------------- TXPadDevice

constructor TXPadDevice.Create;
begin
  inherited Create;
  FMin[0] := 0; FMax[0] := 65535;
  FMin[1] := 0; FMax[1] := 65535;
  FFirst := True;
end;

destructor TXPadDevice.Destroy;
begin
  if GActive <> nil then begin
    GActive.FRunning := False;
    GActive := nil;
  end;
  PadRumble(0, 0);
  inherited;
end;

procedure TXPadDevice.Push(Ofs, Data: DWORD);
begin
  if FQCount >= QSIZE then Exit;
  Inc(FSeq);
  with FQ[FQCount] do begin
    dwOfs := Ofs;
    dwData := Data;
    dwTimeStamp := GetTickCount;
    dwSequence := FSeq;
    uAppData := 0;
  end;
  Inc(FQCount);
end;

procedure TXPadDevice.Compute(var Axis0, Axis1: LongInt; var Pov: DWORD; var Btn: array of Boolean);
var
  St: TXInputState;
  Src: TSrcArray;
  w: Word;
  nx, ny: Double;
  i: Integer;
  L, R, U, D: Boolean;
begin
  FillChar(St, SizeOf(St), 0);
  PadSnapshot(St);
  w := St.Gamepad.wButtons;

  nx := Norm(St.Gamepad.sThumbLX, GCfg.DeadZone);
  ny := -Norm(St.Gamepad.sThumbLY, GCfg.DeadZone);  // в DirectInput Y вниз = плюс

  L := (w and XINPUT_GAMEPAD_DPAD_LEFT) <> 0;
  R := (w and XINPUT_GAMEPAD_DPAD_RIGHT) <> 0;
  U := (w and XINPUT_GAMEPAD_DPAD_UP) <> 0;
  D := (w and XINPUT_GAMEPAD_DPAD_DOWN) <> 0;

  if GCfg.DpadAxes then begin
    if nx = 0 then begin
      if L then nx := -1 else if R then nx := 1;
    end;
    if ny = 0 then begin
      if U then ny := -1 else if D then ny := 1;
    end;
  end;

  Axis0 := (FMin[0] + FMax[0]) div 2 + Round(nx * ((FMax[0] - FMin[0]) div 2));
  Axis1 := (FMin[1] + FMax[1]) div 2 + Round(ny * ((FMax[1] - FMin[1]) div 2));

  // крестовина -> POV (сотые доли градуса, -1 = центр)
  Pov := $FFFFFFFF;
  if U and R then Pov := 4500
  else if D and R then Pov := 13500
  else if D and L then Pov := 22500
  else if U and L then Pov := 31500
  else if U then Pov := 0
  else if R then Pov := 9000
  else if D then Pov := 18000
  else if L then Pov := 27000;

  // кнопки джойстика: только источники, назначенные на JOYn (IsKey = False)
  for i := 0 to High(Btn) do Btn[i] := False;
  ComputeSources(St, Src);
  for i := 0 to SRC_COUNT - 1 do
    if Src[i] and (not GBind[i].IsKey) and (GBind[i].Code >= 0) and (GBind[i].Code <= High(Btn)) then
      Btn[GBind[i].Code] := True;
end;

procedure TXPadDevice.Refresh;
var
  a0, a1: LongInt;
  pov: DWORD;
  btn: array[0..31] of Boolean;
  i: Integer;
begin
  if GActive <> nil then GActive.Tick;
  Compute(a0, a1, pov, btn);

  if FFirst or (a0 <> FPrevAxis[0]) then Push(DIJOFS_X, DWORD(a0));
  if FFirst or (a1 <> FPrevAxis[1]) then Push(DIJOFS_Y, DWORD(a1));
  if FFirst or (pov <> FPrevPov) then Push(DIJOFS_POV0, pov);
  for i := 0 to 31 do
    if btn[i] <> FPrevBtn[i] then begin
      if btn[i] then Push(DIJOFS_BUTTON0 + DWORD(i), $80)
      else Push(DIJOFS_BUTTON0 + DWORD(i), 0);
      FPrevBtn[i] := btn[i];
    end;
  FPrevAxis[0] := a0;
  FPrevAxis[1] := a1;
  FPrevPov := pov;
  FFirst := False;
end;

function TXPadDevice.GetCapabilities(lpDIDevCaps: Pointer): HResult;
var
  C: PDIDevCaps;
  sz: DWORD;
begin
  C := PDIDevCaps(lpDIDevCaps);
  if C = nil then begin Result := DIERR_INVALIDPARAM; Exit; end;
  sz := C^.dwSize;
  if sz < 24 then begin Result := DIERR_INVALIDPARAM; Exit; end;
  FillChar(lpDIDevCaps^, sz, 0);
  C^.dwSize := sz;
  C^.dwFlags := $00000001 or $00000100;   // DIDC_ATTACHED | DIDC_FORCEFEEDBACK
  C^.dwDevType := $00000204;
  C^.dwAxes := 2;
  C^.dwButtons := GCfg.NumButtons;
  C^.dwPOVs := 1;
  if sz >= SizeOf(TDIDevCaps) then begin
    C^.dwFFSamplePeriod := 1000;
    C^.dwFFMinTimeResolution := 1000;
  end;
  Result := DI_OK;
end;

function TXPadDevice.EnumObjects(lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.GetProperty(rguidProp: DWORD; pdiph: Pointer): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.SetProperty(rguidProp: DWORD; pdiph: Pointer): HResult;
var
  H: PDWORD;
  Hdr: array[0..5] of DWORD;
  i: Integer;
begin
  Result := DI_OK;
  if (rguidProp = 4) and (pdiph <> nil) then begin   // DIPROP_RANGE
    H := PDWORD(pdiph);
    Move(H^, Hdr, SizeOf(Hdr));
    // Hdr: size, headerSize, obj, how, min, max
    for i := 0 to 1 do
      if (Hdr[3] = DIPH_DEVICE) or ((Hdr[3] = DIPH_BYOFFSET) and (Hdr[2] = DWORD(i * 4))) then begin
        FMin[i] := LongInt(Hdr[4]);
        FMax[i] := LongInt(Hdr[5]);
      end;
    Log('SetProperty RANGE how=' + IntToStr(Hdr[3]) + ' obj=' + IntToStr(Hdr[2]) +
        ' ' + IntToStr(LongInt(Hdr[4])) + '..' + IntToStr(LongInt(Hdr[5])));
  end;
end;

function TXPadDevice.Acquire: HResult;
begin
  FAcquired := True;
  FFirst := True;
  FQCount := 0;
  FillChar(FPrevBtn, SizeOf(FPrevBtn), 0);
  Log('Acquire');
  Result := DI_OK;
end;

function TXPadDevice.Unacquire: HResult;
begin
  FAcquired := False;
  if GActive <> nil then GActive.FRunning := False;
  PadRumble(0, 0);
  Log('Unacquire');
  Result := DI_OK;
end;

function TXPadDevice.GetDeviceState(cbData: DWORD; lpvData: Pointer): HResult;
var
  a0, a1: LongInt;
  pov: DWORD;
  btn: array[0..31] of Boolean;
  P: Pointer;
  i: Integer;
begin
  if not FAcquired then begin Result := DIERR_NOTACQUIRED; Exit; end;
  if (lpvData = nil) or (cbData < 80) then begin Result := DIERR_INVALIDPARAM; Exit; end;
  if GActive <> nil then GActive.Tick;
  Compute(a0, a1, pov, btn);
  FillChar(lpvData^, cbData, 0);
  P := lpvData;
  PLongInt(P)^ := a0;
  PLongInt(At(P, 4))^ := a1;
  for i := 2 to 5 do
    PLongInt(At(P, i * 4))^ := (FMin[0] + FMax[0]) div 2;   // Z..Rz в центре
  PDWORD(At(P, 32))^ := pov;
  PDWORD(At(P, 36))^ := $FFFFFFFF;
  PDWORD(At(P, 40))^ := $FFFFFFFF;
  PDWORD(At(P, 44))^ := $FFFFFFFF;
  for i := 0 to 31 do
    if btn[i] then PByte(At(P, 48 + i))^ := $80;
  Result := DI_OK;
end;

function TXPadDevice.GetDeviceData(cbObjectData: DWORD; rgdod: Pointer; var pdwInOut: DWORD; dwFlags: DWORD): HResult;
var
  n, i: Integer;
  cb: DWORD;
begin
  if not FAcquired then begin
    pdwInOut := 0;
    Result := DIERR_NOTACQUIRED;
    Exit;
  end;
  Refresh;
  if rgdod = nil then begin
    // сброс буфера
    pdwInOut := FQCount;
    if (dwFlags and DIGDD_PEEK) = 0 then FQCount := 0;
    Result := DI_OK;
    Exit;
  end;
  n := FQCount;
  if Integer(pdwInOut) < n then n := Integer(pdwInOut);
  cb := cbObjectData;
  if cb > SizeOf(TDIDeviceObjectData) then cb := SizeOf(TDIDeviceObjectData);
  for i := 0 to n - 1 do begin
    FillChar(At(rgdod, i * Integer(cbObjectData))^, cbObjectData, 0);
    Move(FQ[i], At(rgdod, i * Integer(cbObjectData))^, cb);
  end;
  if (dwFlags and DIGDD_PEEK) = 0 then begin
    for i := n to FQCount - 1 do FQ[i - n] := FQ[i];
    Dec(FQCount, n);
  end;
  pdwInOut := n;
  Result := DI_OK;
end;

function TXPadDevice.SetDataFormat(lpdf: Pointer): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.SetEventNotification(hEvent: THandle): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.SetCooperativeLevel(hwnd: HWND; dwFlags: DWORD): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.GetObjectInfo(pdidoi: Pointer; dwObj: DWORD; dwHow: DWORD): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.GetDeviceInfo(pdidi: Pointer): HResult;
begin
  if pdidi = nil then begin Result := DIERR_INVALIDPARAM; Exit; end;
  FillInstance(PDIDeviceInstanceA(pdidi)^);
  Result := DI_OK;
end;

function TXPadDevice.RunControlPanel(hwndOwner: HWND; dwFlags: DWORD): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.Initialize(hinst: THandle; dwVersion: DWORD; const rguid: TGUID): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.CreateEffect(const rguid: TGUID; lpeff: Pointer; out ppdeff: IDirectInputEffect; punkOuter: IUnknown): HResult;
var
  E: TXPadEffect;
begin
  E := TXPadEffect.Create(rguid);
  E.Parse(PDIEffect(lpeff), DIEP_DURATION or DIEP_GAIN or DIEP_TYPESPECIFICPARAMS);
  ppdeff := E;
  Log('CreateEffect');
  Result := DI_OK;
end;

function TXPadDevice.EnumEffects(lpCallback: Pointer; pvRef: Pointer; dwEffType: DWORD): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.GetEffectInfo(pdei: Pointer; const rguid: TGUID): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.GetForceFeedbackState(var pdwOut: DWORD): HResult;
begin
  pdwOut := 0;
  Result := DI_OK;
end;

function TXPadDevice.SendForceFeedbackCommand(dwFlags: DWORD): HResult;
begin
  if (dwFlags and (DISFFC_RESET or DISFFC_STOPALL)) <> 0 then begin
    if GActive <> nil then GActive.FRunning := False;
    PadRumble(0, 0);
  end;
  Result := DI_OK;
end;

function TXPadDevice.EnumCreatedEffectObjects(lpCallback: Pointer; pvRef: Pointer; fl: DWORD): HResult;
begin
  Result := DI_OK;
end;

function TXPadDevice.Escape(pesc: Pointer): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.Poll: HResult;
begin
  if not FAcquired then begin Result := DIERR_NOTACQUIRED; Exit; end;
  Refresh;
  Result := DI_OK;
end;

function TXPadDevice.SendDeviceData(cbObjectData: DWORD; rgdod: Pointer; var pdwInOut: DWORD; fl: DWORD): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.EnumEffectsInFile(lpszFileName: PAnsiChar; pec: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.WriteEffectToFile(lpszFileName: PAnsiChar; dwEntries: DWORD; pPeff: Pointer; dwFlags: DWORD): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.BuildActionMap(lpdiaf: Pointer; lpszUserName: PAnsiChar; dwFlags: DWORD): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.SetActionMap(lpdiActionFormat: Pointer; lptszUserName: PAnsiChar; dwFlags: DWORD): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

function TXPadDevice.GetImageInfo(lpdiDevImageInfoHeader: Pointer): HResult;
begin
  Result := DIERR_UNSUPPORTED;
end;

initialization
  InitializeCriticalSection(GCS);

finalization
  DeleteCriticalSection(GCS);

end.
