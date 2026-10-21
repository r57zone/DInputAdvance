unit DI8Types;
{ Объявления DirectInput8 (ANSI).
  Порядок методов в интерфейсах = порядок в vtable DirectInput, НЕ МЕНЯТЬ! }

interface

uses Windows, SysUtils;

const
  DI_OK                 = HRESULT(0);
  DI_NOEFFECT           = HRESULT(1);   // S_FALSE
  DIERR_NOTACQUIRED     = HRESULT($8007000C);
  DIERR_INVALIDPARAM    = HRESULT($80070057);
  DIERR_UNSUPPORTED     = HRESULT($80004001); // E_NOTIMPL
  DIERR_GENERIC         = HRESULT($80004005); // E_FAIL
  DIERR_NOINTERFACE_    = HRESULT($80004002);

  DI8DEVCLASS_GAMECTRL  = 4;
  DIGDD_PEEK            = 1;

  DIPH_DEVICE           = 0;
  DIPH_BYOFFSET         = 1;

  DIEP_DURATION         = $00000001;
  DIEP_GAIN             = $00000004;
  DIEP_TYPESPECIFICPARAMS = $00000100;
  DIEP_START            = $20000000;

  DISFFC_RESET          = 1;
  DISFFC_STOPALL        = 2;

  DIJOFS_X              = 0;
  DIJOFS_Y              = 4;
  DIJOFS_POV0           = 32;
  DIJOFS_BUTTON0        = 48;


type
  TDIDeviceObjectData = packed record
    dwOfs: DWORD;
    dwData: DWORD;
    dwTimeStamp: DWORD;
    dwSequence: DWORD;
    uAppData: DWORD;
  end;
  PDIDeviceObjectData = ^TDIDeviceObjectData;

  TDIDevCaps = packed record
    dwSize: DWORD;
    dwFlags: DWORD;
    dwDevType: DWORD;
    dwAxes: DWORD;
    dwButtons: DWORD;
    dwPOVs: DWORD;
    dwFFSamplePeriod: DWORD;
    dwFFMinTimeResolution: DWORD;
    dwFirmwareRevision: DWORD;
    dwHardwareRevision: DWORD;
    dwFFDriverVersion: DWORD;
  end;
  PDIDevCaps = ^TDIDevCaps;

  TDIDeviceInstanceA = packed record
    dwSize: DWORD;
    guidInstance: TGUID;
    guidProduct: TGUID;
    dwDevType: DWORD;
    tszInstanceName: array[0..259] of AnsiChar;
    tszProductName: array[0..259] of AnsiChar;
    guidFFDriver: TGUID;
    wUsagePage: Word;
    wUsage: Word;
  end;
  PDIDeviceInstanceA = ^TDIDeviceInstanceA;

  TDIEffect = packed record
    dwSize: DWORD;
    dwFlags: DWORD;
    dwDuration: DWORD;
    dwSamplePeriod: DWORD;
    dwGain: DWORD;
    dwTriggerButton: DWORD;
    dwTriggerRepeatInterval: DWORD;
    cAxes: DWORD;
    rgdwAxes: Pointer;
    rglDirection: Pointer;
    lpEnvelope: Pointer;
    cbTypeSpecificParams: DWORD;
    lpvTypeSpecificParams: Pointer;
    dwStartDelay: DWORD;
  end;
  PDIEffect = ^TDIEffect;

  TDIPeriodic = packed record
    dwMagnitude: DWORD;
    lOffset: LongInt;
    dwPhase: DWORD;
    dwPeriod: DWORD;
  end;
  PDIPeriodic = ^TDIPeriodic;

  TDIEnumDevicesCallbackA = function(lpddi: PDIDeviceInstanceA; pvRef: Pointer): BOOL; stdcall;

  IDirectInputEffect = interface(IUnknown)
    ['{E7E1F7C0-88D2-11D0-9AD0-00A0C9A06E35}']
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

  IDirectInputDevice8A = interface(IUnknown)
    ['{54D41080-DC15-4833-A41B-748F73A38179}']
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

  IDirectInput8A = interface(IUnknown)
    ['{BF798030-483A-4DA2-AA99-5D64ED369700}']
    function CreateDevice(const rguid: TGUID; out lplpDirectInputDevice: IDirectInputDevice8A; pUnkOuter: IUnknown): HResult; stdcall;
    function EnumDevices(dwDevType: DWORD; lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult; stdcall;
    function GetDeviceStatus(const rguidInstance: TGUID): HResult; stdcall;
    function RunControlPanel(hwndOwner: HWND; dwFlags: DWORD): HResult; stdcall;
    function Initialize(hinst: THandle; dwVersion: DWORD): HResult; stdcall;
    function FindDevice(const rguidClass: TGUID; ptszName: PAnsiChar; out pguidInstance: TGUID): HResult; stdcall;
    function EnumDevicesBySemantics(ptszUserName: PAnsiChar; lpdiActionFormat: Pointer; lpCallback: Pointer; pvRef: Pointer; dwFlags: DWORD): HResult; stdcall;
    function ConfigureDevices(lpdiCallback: Pointer; lpdiCDParams: Pointer; dwFlags: DWORD; pvRefData: Pointer): HResult; stdcall;
  end;

const
  IID_IDirectInput8A: TGUID = '{BF798030-483A-4DA2-AA99-5D64ED369700}';

  // наш виртуальный геймпад (произвольные GUID)
  GUID_XPadInstance: TGUID = '{5850AD00-0001-4E4F-8A1C-DE57FA4B0001}';
  GUID_XPadProduct:  TGUID = '{028E045E-0000-0000-0000-504944564944}';

function SameGuid(const A, B: TGUID): Boolean;

implementation

function SameGuid(const A, B: TGUID): Boolean;
begin
  Result := CompareMem(@A, @B, SizeOf(TGUID));
end;

end.
