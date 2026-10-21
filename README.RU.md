[![EN](https://user-images.githubusercontent.com/9499881/33184537-7be87e86-d096-11e7-89bb-f3286f752bc6.png)](https://github.com/r57zone/DInputAdvance/) 
[![RU](https://user-images.githubusercontent.com/9499881/27683795-5b0fbac6-5cd8-11e7-929c-057833e01fb1.png)](https://github.com/r57zone/DInputAdvance/blob/master/README.RU.md)

# DInputAdvance
Прокси-обёртка DirectInput, которая эмулирует DirectInput-устройство для XInput-контроллеров и позволяет назначать кнопки клавиатуры на кнопки геймпада.

Работает с играми, которые используют ввод DirectInput 8 (`dinput8.dll`). Некоторые игры на DirectX 7 тоже используют ввод DirectInput 8, поэтому подходят.

## Загрузка
>Поддерживается Windows XP, Vista, 7, 8, 8.1, 10, 11.

**[Загрузить](https://github.com/r57zone/DInputAdvance/releases)**

## Возможности
- XInput-контроллер работает как родной DirectInput-геймпад.
- Поддержка вибрации.
- Горячее подключение.
- Любую кнопку можно назначить на кнопку джойстика или клавишу клавиатуры.

## Установка
Скопируйте `dinput8.dll` и `dinput8.ini` в папку с `.exe` игры.

## Настройки
Отредактируйте `dinput8.ini`:

| Параметр | По умолчанию | Описание |
| --- | --- | --- |
| `DeadZone` | `24` | Мёртвая зона левого стика, % |
| `TriggerThreshold` | `24` | Порог срабатывания LT/RT, % |
| `StickThreshold` | `50` | Порог срабатывания направлений стика (`LS-UP`, `RS-LEFT` и т.д.), % |
| `RumbleScale` | `100` | Сила вибрации, % |

### Назначение кнопок
Кнопки: `A`, `B`, `X`, `Y`, `LB`, `RB`, `BACK`, `START`, `LS`, `RS`, `LT`, `RT`, `UP`, `DOWN`, `LEFT`, `RIGHT`, а также направления стиков `LS-UP`, `LS-DOWN`, `LS-LEFT`, `LS-RIGHT`, `RS-UP`, `RS-DOWN`, `RS-LEFT`, `RS-RIGHT`.

Каждую кнопку можно назначить на:
- `JOY1`–`JOY32` — кнопка джойстика.
- Имя клавиши — `A`–`Z`, `0`–`9`, `F1`–`F12`, `ENTER`, `ESCAPE`, `SPACE`, `TAB`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `NUMPAD0`–`NUMPAD9` и т.д.
- `NONE` — отключено.

```ini
[Buttons]
A=JOY1
B=JOY2
LB=A
BACK=F5
START=ENTER
```

## Благодарности
- `XInput.pas` — XInput для Delphi от Alexey Barkovoy (Clootie), через Project JEDI.
- [Claude AI](https://claude.ai) — за помощь в разработке.

## Обратная связь
`r57zone@gmail.com`
