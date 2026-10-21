unit KeyEmu;
{ Эмуляция клавиатуры через SendInput.

  Ключевая идея: состояние каждой клавиши кэшируется в GKeyDown[].
  KEYDOWN отправляется ровно один раз при нажатии, KEYUP - ровно один раз при
  отпускании. Пока кнопка геймпада удерживается - в Windows ничего не уходит. }

interface

uses Windows, SysUtils;

const
  KEY_EXT = $100;   // флаг "расширенная клавиша" (NumPad Enter и т.п.), VK лежит в младшем байте
  KEY_MAX = $1FF;

type
  // Какие клавиши должны быть нажаты ПРЯМО СЕЙЧАС (индекс = код клавиши)
  TKeyWant = array[0..KEY_MAX] of Boolean;

// Имя клавиши -> код (VK, возможно с флагом KEY_EXT). 0 = NONE / неизвестное имя.
function KeyFromName(const Name: string): Integer;

// True, если активное окно принадлежит этому процессу (игре)
function GameHasFocus: Boolean;

// Привести реальное состояние клавиш к Want: шлём только изменения
procedure KeysApply(const Want: TKeyWant);

// Отпустить всё, что сейчас нажато нами
procedure KeysReleaseAll;

implementation

const
  MAPVK_VK_TO_VSC = 0;

type
  TKeyDef = record
    Name: string;
    Code: Integer;
  end;

var
  GKeyDown: array[0..KEY_MAX] of Boolean;   // кэш: что мы уже отправили в систему
  GKeyCS: TRTLCriticalSection;
  Tab: array of TKeyDef;
  TabN: Integer = 0;

// ------------------------------------------------------------ таблица имён

procedure Reg(const N: string; C: Integer);
begin
  if TabN >= Length(Tab) then SetLength(Tab, TabN + 64);
  Tab[TabN].Name := N;
  Tab[TabN].Code := C;
  Inc(TabN);
end;

procedure BuildTable;
var
  i: Integer;
begin
  Reg('ESCAPE', VK_ESCAPE);
  Reg('ESC', VK_ESCAPE);
  for i := 1 to 24 do Reg('F' + IntToStr(i), VK_F1 + i - 1);

  Reg('~', 192);
  for i := 0 to 9 do Reg(Chr(Ord('0') + i), Ord('0') + i);
  Reg('-', 189);
  Reg('=', 187);

  Reg('TAB', VK_TAB);
  Reg('CAPS-LOCK', VK_CAPITAL);
  Reg('SHIFT', VK_SHIFT);
  Reg('LSHIFT', VK_LSHIFT);
  Reg('RSHIFT', VK_RSHIFT);
  Reg('CTRL', VK_CONTROL);
  Reg('LCTRL', VK_LCONTROL);
  Reg('RCTRL', VK_RCONTROL);
  Reg('WIN', VK_LWIN);
  Reg('ALT', VK_MENU);
  Reg('LALT', VK_LMENU);
  Reg('RALT', VK_RMENU);
  Reg('SPACE', VK_SPACE);
  Reg('ENTER', VK_RETURN);
  Reg('BACKSPACE', VK_BACK);

  for i := 0 to 25 do Reg(Chr(Ord('A') + i), Ord('A') + i);

  Reg('[', 219);
  Reg(']', 221);
  Reg(':', 186);
  Reg(';', 186);
  Reg('APOSTROPHE', 222);
  Reg('\', 220);
  Reg('<', 188);
  Reg(',', 188);
  Reg('>', 190);
  Reg('.', 190);
  Reg('?', 191);
  Reg('/', 191);

  Reg('PRINTSCREEN', VK_SNAPSHOT);
  Reg('SCROLL-LOCK', VK_SCROLL);
  Reg('PAUSE', VK_PAUSE);
  Reg('INSERT', VK_INSERT);
  Reg('HOME', VK_HOME);
  Reg('DELETE', VK_DELETE);
  Reg('END', VK_END);
  Reg('PAGE-UP', VK_PRIOR);
  Reg('PAGE-DOWN', VK_NEXT);

  Reg('UP', VK_UP);
  Reg('DOWN', VK_DOWN);
  Reg('LEFT', VK_LEFT);
  Reg('RIGHT', VK_RIGHT);

  Reg('NUM-LOCK', VK_NUMLOCK);
  for i := 0 to 9 do Reg('NUMPAD' + IntToStr(i), VK_NUMPAD0 + i);
  Reg('NUMPAD-DIVIDE', VK_DIVIDE);
  Reg('NUMPAD-MULTIPLY', VK_MULTIPLY);
  Reg('NUMPAD-MINUS', VK_SUBTRACT);
  Reg('NUMPAD-PLUS', VK_ADD);
  Reg('NUMPAD-DEL', VK_DECIMAL);
  Reg('NUMPAD-ENTER', VK_RETURN or KEY_EXT);
end;

function KeyFromName(const Name: string): Integer;
var
  i: Integer;
  S: string;
begin
  Result := 0;
  S := UpperCase(Trim(Name));
  if (S = '') or (S = 'NONE') then Exit;
  if TabN = 0 then BuildTable;
  for i := 0 to TabN - 1 do
    if Tab[i].Name = S then begin
      Result := Tab[i].Code;
      Exit;
    end;
  // запасной вариант для любых других клавиш: 0x41 = VK-код в hex
  if Copy(S, 1, 2) = '0X' then begin
    i := StrToIntDef('$' + Copy(S, 3, 4), 0);
    if (i > 0) and (i <= KEY_MAX) then Result := i;
  end;
end;

// ------------------------------------------------------------ SendInput

function IsExtendedVK(VK: Integer): Boolean;
begin
  case VK of
    VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT,
    VK_INSERT, VK_DELETE, VK_HOME, VK_END, VK_PRIOR, VK_NEXT,
    VK_RCONTROL, VK_RMENU, VK_DIVIDE, VK_NUMLOCK, VK_SNAPSHOT,
    VK_LWIN, VK_RWIN:
      Result := True;
  else
    Result := False;
  end;
end;

procedure SendKey(Code: Integer; Down: Boolean);
var
  Input: TInput;
  VK: Integer;
  Flags: DWORD;
begin
  VK := Code and $FF;
  FillChar(Input, SizeOf(Input), 0);
  Input.Itype := INPUT_KEYBOARD;
  Input.ki.wVk := Word(VK);
  Input.ki.wScan := Word(MapVirtualKey(VK, MAPVK_VK_TO_VSC));
  Input.ki.dwExtraInfo := 0;

  Flags := 0;
  if ((Code and KEY_EXT) <> 0) or IsExtendedVK(VK) then Flags := KEYEVENTF_EXTENDEDKEY;
  if not Down then Flags := Flags or KEYEVENTF_KEYUP;
  Input.ki.dwFlags := Flags;

  SendInput(1, Input, SizeOf(Input));
end;

function GameHasFocus: Boolean;
var
  H: HWND;
  Pid: DWORD;
begin
  Pid := 0;
  H := GetForegroundWindow;
  if H <> 0 then GetWindowThreadProcessId(H, @Pid);
  Result := (H <> 0) and (Pid = GetCurrentProcessId);
end;

procedure KeysApply(const Want: TKeyWant);
var
  i: Integer;
begin
  EnterCriticalSection(GKeyCS);
  try
    for i := 1 to KEY_MAX do
      if Want[i] <> GKeyDown[i] then begin
        SendKey(i, Want[i]);      // одно событие на смену состояния
        GKeyDown[i] := Want[i];
      end;
  finally
    LeaveCriticalSection(GKeyCS);
  end;
end;

procedure KeysReleaseAll;
var
  i: Integer;
begin
  EnterCriticalSection(GKeyCS);
  try
    for i := 1 to KEY_MAX do
      if GKeyDown[i] then begin
        SendKey(i, False);
        GKeyDown[i] := False;
      end;
  finally
    LeaveCriticalSection(GKeyCS);
  end;
end;

initialization
  InitializeCriticalSection(GKeyCS);

finalization
  DeleteCriticalSection(GKeyCS);

end.
