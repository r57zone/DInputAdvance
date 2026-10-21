[![EN](https://user-images.githubusercontent.com/9499881/33184537-7be87e86-d096-11e7-89bb-f3286f752bc6.png)](https://github.com/r57zone/DInputAdvance/) 
[![RU](https://user-images.githubusercontent.com/9499881/27683795-5b0fbac6-5cd8-11e7-929c-057833e01fb1.png)](https://github.com/r57zone/DInputAdvance/blob/master/README.RU.md)
 ← Choose language | Выберите язык

# DInputAdvance
DirectInput proxy wrapper that makes XInput controllers appear as DirectInput devices, with optional keyboard button mapping.

Works with games that use DirectInput 8 (`dinput8.dll`) for input. Some DirectX 7 games also use DirectInput 8 for input, so they are supported too.

## Download
>Supports Windows XP, Vista, 7, 8, 8.1, 10, 11.

**[Download](https://github.com/r57zone/DInputAdvance/releases)**

## Features
- XInput controller works as a native DirectInput gamepad.
- Vibration support.
- Hot-plugging.
- Any button can be mapped to a joystick button or a keyboard key.

## Installation
Copy `dinput8.dll` and `dinput8.ini` next to the game's `.exe`.

## Settings
Edit `dinput8.ini`:

| Option | Default | Description |
| --- | --- | --- |
| `DeadZone` | `24` | Left stick dead zone, % |
| `TriggerThreshold` | `24` | LT/RT press threshold, % |
| `StickThreshold` | `50` | Stick direction press threshold (`LS-UP`, `RS-LEFT`, etc.), % |
| `RumbleScale` | `100` | Vibration strength, % |

### Button mapping
Buttons: `A`, `B`, `X`, `Y`, `LB`, `RB`, `BACK`, `START`, `LS`, `RS`, `LT`, `RT`, `UP`, `DOWN`, `LEFT`, `RIGHT`, and stick directions `LS-UP`, `LS-DOWN`, `LS-LEFT`, `LS-RIGHT`, `RS-UP`, `RS-DOWN`, `RS-LEFT`, `RS-RIGHT`.

Each button can be set to:
- `JOY1`–`JOY32` — joystick button.
- Key name — `A`–`Z`, `0`–`9`, `F1`–`F12`, `ENTER`, `ESCAPE`, `SPACE`, `TAB`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `NUMPAD0`–`NUMPAD9`, etc.
- `NONE` — disabled.

```ini
[Buttons]
A=JOY1
B=JOY2
LB=A
BACK=F5
START=ENTER
```

## Credits
- `XInput.pas` — XInput for Delphi by Alexey Barkovoy (Clootie), via Project JEDI.
- [Claude AI](https://claude.ai) — for help with development.

## Feedback
`r57zone@gmail.com`
