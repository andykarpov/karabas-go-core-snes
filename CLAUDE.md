# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A port of the SNES core of SNES_MiSTer (srg320), through its MiST branch [gyurco/SNES_FPGA](https://github.com/gyurco/SNES_FPGA), to the Karabas Go, Mini and Mini G boards: Xilinx Spartan-6 XC6SLX25, ISE 14.7 (XST). Mini G is the first board (`src/rtl/karabas_minig_top.v`); Go and Mini follow. The plan and the state of the work are in `docs/PLAN.md` (Russian): follow its phases and update it when a decision changes; its "Результаты Ф0" have the numbers that drive the design (LUTs, block RAMs).

The board modules (MCU link, memories, clocks, DACs, OSD, DVI) come from the git submodule `modules/` ([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)); clone with `--recursive` or run `git submodule update --init`. A change to them is made there and taken here by updating the submodule commit. Its `CLAUDE.md` has the rules (Verilog-2001 for XST, no coregen, tests, checks of LUTs and timing).

## Build

- `cd src && make` builds the boards of `BOARDS` in the Makefile (now `minig`: `make minig`, `make minig-xst`, `-impl`, `-core` one step, `make minig-report` the utilization and timing of the last build). It runs the ISE command-line flow and sources `/opt/Xilinx/14.7/ISE_DS/settings64.sh` (`ISE_SETTINGS=` to change it).
- Inputs per board: `karabas_<board>_top.prj` (the source list, add new files here; the shared modules as `"../modules/rtl/..."`), `karabas_<board>_top.xst`, `karabas_<board>_top.ut`, `karabas_<board>.ucf` (pins from karabas-go-core-nes, then the timing block).
- `core` packs `karabas_<board>_top.bin` with `core_minig.json` into `snes.kg3` with `make_core.py`, a symlink to karabas-go-tools (the sibling repo must be checked out next to this one). The json `osd` items are the soft switch registers in their order (`kg_soft_switches` in the top); Reset stays last.
- Init files of memories are read by XST relative to `src/` (the DSPn ROMs: `rtl/snes/chip/DSP/dsp11b23410_*.txt`, made by `src/tools/mif2bin.py` from the `.mif` of upstream).
- `src/fit/run_fit.sh [top] [area]` synthesizes `main` (or a module of it) alone with XST, memories as ports: the LUT / block RAM count of the SNES without the board (`DSPN=1`, `XCF=area.xcf`).

## Layout

- `src/rtl/snes/`: `rtl/` of SNES_FPGA at b7c50e5 (see docs/PLAN.md), the enhancement chips DSPn, OBC1, SRTC and the LoROM / HiROM mapper only. Local changes are marked `-- karabas:` / `// karabas:` and say why; keep the rest byte for byte as upstream (CRLF kept, `.gitattributes`), so it can be compared. `bram_kg.vhd` replaces `bram.vhd` (altsyncram) with the same entities as inferred memories.
- `src/rtl/snes_system.v`: the SNES without the board: `main`, the requests to the memories (made at the falling clk_sys edge as in SNES.sv of the MiST core), the ROM loader (FILELOAD_* of kg_mcu through a small fifo), `snes_hdr.v` (finds the header in the SDRAM after a load: LoROM / HiROM / ExHiROM, copier header), the cartridge type, `snes_joy.v` (the controllers).
- `src/rtl/mem/`: `snes_sdram.v` (ROM and WRAM), `snes_sram.v` (VRAM, ARAM, BSRAM, an io port), `snes_phase.v`. Both controllers run on clk_mem = 4 x clk_sys and answer at the clk_mem edge of a rising clk_sys edge only (`TS_MEM_ANSWER` of the ucf).
- `src/rtl/video/snes_video.v`: the 15 kHz picture to 31 kHz with a line buffer and clk_sys as the pixel clock, the 640 x 480 DE window.
- `src/rtl/karabas_minig_top.v`: clocks (`kg_pll`: clk_sys 21.484 MHz, clk_mem 85.94 MHz; `kg_dcm` x5 for the serialisers), `kg_mcu`, soft switches, joysticks, video -> `kg_osd_overlay` -> DVI, PCM5102.

## Simulation

- `src/sim/mem/run_mem_sim.sh` (iverilog): the memory controllers against models of the chips with the delays of the board, several ports at once, every read checked, a watchdog for lost requests; outside the timing windows the tests must fail (they print so).
- `src/sim/sys/run_sys_sim.sh` (iverilog): `tb_hdr.v`, the header detection on built images.
- `src/sim/eq/run_eq.sh` (ghdl): the karabas changes of upstream VHDL against the originals in `sim/eq/ref` (the microcode tables).
- A test is only worth something if it fails without the code it covers: break the module in a scratch copy and see the test fail (each of the tests above was checked so).

## Constraints that drive the changes

- **XST**: Verilog-2001 only (no SystemVerilog: upstream `.sv` files are rewritten, e.g. `ioport.sv` -> `snes_joy.v`; no declarations after use; no `inside` and other SV keywords as names). The VHDL of upstream is mostly accepted; a `case` on std_logic needs `others`, a Verilog parameter reaches a VHDL generic only as an integer.
- **The XC6SLX25 is small**: the SNES alone is ~12.3k LUTs of 15k. Every addition is checked against the LUT count (`*_map.mrp`). Memories must be inferable as block RAM (synchronous read, no reset of the data register): that is why the microcode tables were changed.
- **Clocks**: one PLL, clk_mem = 4 x clk_sys with phase 0, so the paths between them are analysed by the derived PERIODs. Requests go clk_sys (falling edge) -> clk_mem; answers clk_mem -> clk_sys only at ph 0.

## Conventions

- Commit messages explain why a change was needed and what it costs or changes (LUT counts before and after, latency), and say "No functional change." when that is the case.
