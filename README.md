# SNES core for Karabas Go / Mini / Mini G

[Русская версия](README.ru.md)

A Super Nintendo (Super Famicom) for the Karabas Go family of boards. It is a port of
[SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer) by srg320, through its MiST version
[SNES_FPGA](https://github.com/gyurco/SNES_FPGA) by gyurco, to the Xilinx Spartan-6 XC6SLX25 of the
Karabas boards.

| Board | Core file | Video | Audio |
|---|---|---|---|
| Karabas Go | `snes.kg1` | VGA, 640x480 60 Hz | I2S DAC (PCM5102) |
| Karabas Mini | `snes.kg2` | HDMI, 640x480 60 Hz | HDMI, analog output (sigma-delta) |
| Karabas Mini G | `snes.kg3` | HDMI, 640x480 60 Hz | HDMI, I2S DAC (PCM5102) |

The core files are in `src/` and in the release repos
([karabas-go](https://github.com/andykarpov/karabas-go),
[karabas-mini](https://github.com/andykarpov/karabas-mini)). They contain no game ROMs.

**State:** the Mini G build is tested on hardware (games, HDMI picture and sound). The Mini and Go
builds are made from the same sources and are not tested on hardware yet.

## What it does

- **The SNES of SNES_MiSTer:** 65C816 CPU, PPU, SPC700 and DSP sound, DMA / HDMA.
- **Cartridges:** LoROM, HiROM and ExHiROM, up to 8 MB. The type is found from the header of the
  ROM (with or without the 512-byte copier header); the OSD item ROM type overrides it.
- **Enhancement chips:** DSP-1 (DSPn: Super Mario Kart, Pilotwings and others), OBC1, S-RTC.
  Not there: SuperFX (GSU), SA-1, CX4, S-DD1, SPC7110, MSU-1: they do not fit into the XC6SLX25.
- **Memory:** ROM and WRAM in the SDRAM of the board; VRAM, ARAM and the cartridge RAM in its SRAM.
- **Video:** the 256 / 512-pixel picture of the SNES line-doubled to 640x480 at 60 Hz (512x448 in the
  middle, 239-line overscan cut at the bottom). HDMI with the AVI InfoFrame and sound on Mini and
  Mini G; plain DVI when the firmware is set to DVI.
- **Audio:** the 32 kHz stereo of the DSP over HDMI, the PCM5102 DAC (Go, Mini G) or the analog
  output (Mini).
- **Input:** two SNES pads: the joysticks of the board, USB gamepads or the USB keyboard.

Not there yet: saves of the cartridge RAM (`.srm`: the RAM is lost when another game is loaded or
the board is switched off), the SPC player, mouse, multitap, cheats.

## Getting started

1. Copy `snes.kg1` (Go), `snes.kg2` (Mini) or `snes.kg3` (Mini G) to the root of the SD card of
   the board.
2. Put your ROM files (`.sfc`, `.smc`, `.bin`) into the folder `/snes` of the SD card.
3. Choose SNES in the core menu and pick a ROM in the file browser. The game starts when it is
   loaded.

## OSD menu

| Item | Values | Hotkey |
|---|---|---|
| ROM type | Auto / LoROM / HiROM / ExHiROM | Menu+M |
| Region | Auto / NTSC / PAL | Menu+R |
| Swap joysticks | Off / On | Menu+J |
| Reset | resets the SNES | F12 |

"Menu" is the Windows key of the keyboard. The file browser of the firmware does not show these
items yet; until it does, the defaults (Auto, Auto, Off) are used.

## PAL games

The output is always 60 Hz: the test monitors of the author did not show 50 Hz modes. With Region
Auto a PAL game therefore runs on NTSC timing, about 20 % faster than on a PAL console (music too).
The SNES still tells the game that it is a PAL console (`$213F`), so games do not show the region
warning. Region PAL gives the real PAL timing with the output as 720x576 at 50 Hz (CEA 576p) for
monitors that take it.

## Controls

The SNES buttons on the joysticks of the board and USB gamepads (the gamepads are mapped by the
firmware, `drivers/*.ini` on the SD card):

| Joystick | SNES |
|---|---|
| A / B / C | B / A / L |
| X / Y / Z | Y / X / R |
| Start / Mode | Start / Select |

The USB keyboard is both pads:

| SNES | Pad 1 | Pad 2 |
|---|---|---|
| D-pad | arrows | I J K L |
| B / A | Z / X | O / P |
| Y / X | A / S | 9 / 0 |
| L / R | Q / W | 8 / - |
| Start / Select | Enter / Space | M / N |

## Building

The core is built with Xilinx ISE 14.7 on Linux: `cd src && make` (all three boards, one after the
other), or `make go`, `make mini`, `make minig`; `make minig-report` shows the utilization and the
timing of the last build. The board modules are the submodule `modules/`
([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)): clone with
`git clone --recursive` or run `git submodule update --init`. Packing the `.kg` files needs the
sibling repo [karabas-go-tools](https://github.com/andykarpov/karabas-go-tools) next to this one
(`make_core.py`).

The simulations (iverilog, ghdl) are in `src/sim`. `CLAUDE.md` has the layout and the constraints of
the design, `docs/PLAN.md` (Russian) the plan and the state of the work.

The board firmware is [karabas-go-firmware](https://github.com/andykarpov/karabas-go-firmware).

## Credits and license

- [SNES_MiSTer](https://github.com/MiSTer-devel/SNES_MiSTer): srg320 (CPU, PPU, SPC700, DSP, the
  enhancement chips) and the MiSTer contributors.
- [SNES_FPGA](https://github.com/gyurco/SNES_FPGA), the MiST version: gyurco.
- [snestang](https://github.com/nand2mario/snestang): nand2mario (the rules of the header
  detection, after bsnes).
- Karabas Go boards and the port: Andy Karpov.

The core is under the GNU GPL v3 (`LICENSE`), as SNES_MiSTer and SNES_FPGA are.
