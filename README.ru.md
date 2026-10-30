# Ядро SNES для Karabas Go / Mini / Mini G

[English version](README.md)

Super Nintendo (Super Famicom) для плат семейства Karabas Go. Это порт
[SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) (автор srg320) через его версию для MiST
[SNES_FPGA](https://github.com/gyurco/SNES_FPGA) (автор gyurco) на Xilinx Spartan-6 XC6SLX25 плат
Karabas.

| Плата | Файл ядра | Видео | Звук |
|---|---|---|---|
| Karabas Go | `snes.kg1` | VGA, 640x480 60 Гц | I2S ЦАП (PCM5102) |
| Karabas Mini | `snes.kg2` | HDMI, 640x480 60 Гц | HDMI, аналоговый выход (сигма-дельта) |
| Karabas Mini G | `snes.kg3` | HDMI, 640x480 60 Гц | HDMI, I2S ЦАП (PCM5102) |

Файлы ядра лежат в `src/` и в релизных репозиториях
([karabas-go](https://github.com/andykarpov/karabas-go),
[karabas-mini](https://github.com/andykarpov/karabas-mini)). ROM игр в них нет.

**Состояние:** сборка Mini G проверена на железе (игры, картинка и звук по HDMI). Сборки Mini и Go
сделаны из тех же исходников, на железе ещё не проверены.

## Что умеет

- **SNES из SNES_MiSTer:** процессор 65C816, PPU, звук SPC700 и DSP, DMA / HDMA.
- **Картриджи:** LoROM, HiROM и ExHiROM, до 8 МБ. Тип определяется по заголовку ROM (с 512-байтным
  заголовком копировщика или без него); пункт OSD ROM type задаёт его вручную.
- **Дополнительные чипы:** DSP-1 (DSPn: Super Mario Kart, Pilotwings и другие), OBC1, S-RTC.
  Нет: SuperFX (GSU), SA-1, CX4, S-DD1, SPC7110, MSU-1 — они не помещаются в XC6SLX25.
- **Память:** ROM и WRAM — в SDRAM платы; VRAM, ARAM и RAM картриджа — в её SRAM.
- **Видео:** картинка SNES шириной 256 / 512 точек с удвоением строк в 640x480 при 60 Гц (512x448
  по центру, у режима overscan на 239 строк низ обрезается). HDMI с AVI InfoFrame и звуком на Mini
  и Mini G; чистый DVI, если в настройках прошивки выбран DVI.
- **Звук:** стерео 32 кГц от DSP — по HDMI, на ЦАП PCM5102 (Go, Mini G) или на аналоговый выход
  (Mini).
- **Ввод:** два джойпада SNES: джойстики платы, USB-геймпады или USB-клавиатура.

Пока нет: сохранения RAM картриджа (`.srm`: RAM теряется при загрузке другой игры и при выключении
платы), SPC-плеера, мыши, мультитапа, читов.

## Как начать

1. Скопируйте `snes.kg1` (Go), `snes.kg2` (Mini) или `snes.kg3` (Mini G) в корень SD-карты платы.
2. Положите файлы ROM (`.sfc`, `.smc`, `.bin`) в папку `/snes` SD-карты.
3. Выберите SNES в меню ядер и ROM в файловом браузере. Игра запускается, как только загрузится.

## Меню OSD

| Пункт | Значения | Клавиши |
|---|---|---|
| ROM type | Auto / LoROM / HiROM / ExHiROM | Menu+M |
| Region | Auto / NTSC / PAL | Menu+R |
| Swap joysticks | Off / On | Menu+J |
| Reset | сброс SNES | F12 |

«Menu» — клавиша Windows на клавиатуре. Файловый браузер прошивки эти пункты пока не показывает;
до тех пор действуют значения по умолчанию (Auto, Auto, Off).

## PAL-игры

Выход всегда 60 Гц: тестовые мониторы автора режимы 50 Гц не показали. Поэтому при Region Auto
PAL-игра идёт на тайминге NTSC — примерно на 20 % быстрее, чем на PAL-консоли (музыка тоже). При этом
SNES сообщает игре, что консоль PAL (`$213F`), так что предупреждения о регионе нет. Region PAL даёт
настоящий тайминг PAL с выходом 720x576 при 50 Гц (CEA 576p) — для мониторов, которые его
принимают.

## Управление

Кнопки SNES на джойстиках платы и USB-геймпадах (раскладку геймпадов задаёт прошивка,
`drivers/*.ini` на SD-карте):

| Джойстик | SNES |
|---|---|
| A / B / C | B / A / L |
| X / Y / Z | Y / X / R |
| Start / Mode | Start / Select |

USB-клавиатура — оба джойпада:

| SNES | Джойпад 1 | Джойпад 2 |
|---|---|---|
| Крестовина | стрелки | I J K L |
| B / A | Z / X | O / P |
| Y / X | A / S | 9 / 0 |
| L / R | Q / W | 8 / - |
| Start / Select | Enter / Space | M / N |

## Сборка

Ядро собирается Xilinx ISE 14.7 под Linux: `cd src && make` (все три платы по очереди) или
`make go`, `make mini`, `make minig`; `make minig-report` показывает заполнение и тайминг последней
сборки. Модули плат — сабмодуль `modules/`
([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)): клонируйте с
`git clone --recursive` или выполните `git submodule update --init`. Для упаковки файлов `.kg`
рядом с этим репозиторием нужен [karabas-go-tools](https://github.com/andykarpov/karabas-go-tools)
(`make_core.py`).

Симуляции (iverilog, ghdl) — в `src/sim`. В `CLAUDE.md` описаны структура и ограничения проекта, в
`docs/PLAN.md` — план и состояние работы.

Прошивка платы — [karabas-go-firmware](https://github.com/andykarpov/karabas-go-firmware).

## Авторы и лицензия

- [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer): srg320 (CPU, PPU, SPC700, DSP,
  дополнительные чипы) и участники проекта MiSTer.
- [SNES_FPGA](https://github.com/gyurco/SNES_FPGA), версия для MiST: gyurco.
- [snestang](https://github.com/nand2mario/snestang): nand2mario (правила определения заголовка,
  по bsnes).
- Платы Karabas Go и порт: Andy Karpov.

Ядро распространяется под GNU GPL v3 (`LICENSE`), как SNES_MiSTer и SNES_FPGA.
