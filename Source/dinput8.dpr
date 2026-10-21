library dinput8;
{ Прокси dinput8.dll для SpideyPC.exe:
  кладётся рядом с игрой, XInput-геймпады выглядят для игры как родной DirectInput-джойстик,
  а часть кнопок может эмулировать клавиатуру (см. dinput8.ini). }

uses
  Windows,
  SysUtils,
  DI8Types in 'DI8Types.pas',
  XInput in 'XInput.pas',
  KeyEmu in 'KeyEmu.pas',
  XPad in 'XPad.pas';

type
  TRealCreate = function(hinst: THandle; dwVersion: DWORD; const riidltf: TGUID;
    out ppvOut: Pointer; punkOuter: Pointer): HResult; stdcall;

var
  RealLib: THandle = 0;
  RealCreate: TRealCreate = nil;

procedure LoadReal;
var
  Buf: array[0..MAX_PATH] of Char;
  Path: string;
begin
  if RealLib <> 0 then Exit;
  // настоящий dinput8.dll берём строго из системной папки (SysWOW64 для 32-бит процесса)
  GetSystemDirectory(Buf, MAX_PATH);
  Path := IncludeTrailingPathDelimiter(string(Buf)) + 'dinput8.dll';
  RealLib := LoadLibrary(PChar(Path));
  if RealLib <> 0 then
    RealCreate := GetProcAddress(RealLib, 'DirectInput8Create');
end;

function DirectInput8Create(hinst: THandle; dwVersion: DWORD; const riidltf: TGUID;
  ppvOut: PPointer; punkOuter: Pointer): HResult; stdcall;
var
  Real: Pointer;
  Wrapper: IDirectInput8A;
begin
  LoadReal;
  if not Assigned(RealCreate) then begin
    Result := DIERR_GENERIC;
    Exit;
  end;
  Real := nil;
  Result := RealCreate(hinst, dwVersion, riidltf, Real, punkOuter);
  if (Result < 0) or (Real = nil) then Exit;

  if SameGuid(riidltf, IID_IDirectInput8A) then begin
    Wrapper := TFakeDI8.Create(Real);   // забирает ссылку на Real
    ppvOut^ := Pointer(Wrapper);
    Pointer(Wrapper) := nil;            // отдаём игре ссылку со счётчиком 1
  end else
    ppvOut^ := Real;
end;

procedure DllMain(Reason: Integer);
begin
  if Reason = DLL_PROCESS_DETACH then XPadShutdown;
end;

exports
  DirectInput8Create name 'DirectInput8Create';

begin
  DllProc := @DllMain;
end.
