#!/bin/bash
# Trial synthesis of the SNES core alone (phase 0 of docs/PLAN.md): XST on `main` (or another
# entity) with the memories as ports, no IO buffers, for the LUT / block RAM / DSP48 count and
# the period estimate of XST. Each run works in its own directory under src/fit/build/.
#
#   ./run_fit.sh [top] [area]     top: main (default), SNES, SCPU, SPPU, SMP, DSP, P65C816, ...
#                                 area: -opt_mode Area -opt_level 2 instead of Speed / 1
#
# The generics of main are those of the boards: no savestates, no enhancement chips except the
# LoROM / HiROM mapper (DSP_LHRomMap); USE_DSPn from DSPN (default 0).

set -e
cd "$(dirname "$0")"
FIT=$PWD
RTL=$(cd ../rtl/snes && pwd)
ISE_SETTINGS=${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}

TOP=${1:-main}
MODE=Speed; LEVEL=1
if [ "$2" = area ]; then MODE=Area; LEVEL=2; fi
# XCF=<file>: per module options of XST (MODEL ... opt_mode = area), see area.xcf
XCF=${XCF:-}
DSPN=${DSPN:-0}

D=$FIT/build/${TOP}_${MODE}_dspn$DSPN${XCF:+_$(basename $XCF .xcf)}
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"
cd "$D"
ln -s "$(cd "$FIT/.." && pwd)/rtl" rtl # init files of memories are named relative to src/

VHDL="bram_kg.vhd
65C816/P65816_pkg.vhd 65C816/BCDAdder.vhd 65C816/AddSubBCD.vhd 65C816/ALU.vhd 65C816/AddrGen.vhd 65C816/MCode.vhd 65C816/P65C816.vhd
SPC700/SPC700_pkg.vhd SPC700/AddrGen.vhd SPC700/AddSub.vhd SPC700/ALU.vhd SPC700/BCDAdj.vhd SPC700/MCode.vhd SPC700/MulDiv.vhd SPC700/SPC700.vhd
PPU_PKG.vhd DSP_PKG.vhd CEGen.vhd SWRAM.vhd CPU.vhd PPU.vhd DSP.vhd SMP.vhd SNES.vhd
chip/SRTC.vhd chip/DSP/OBC1.vhd chip/DSP/DSPn.vhd chip/DSP/DSP_LHRomMap.vhd"
{
	for f in $VHDL; do echo "vhdl work \"$RTL/$f\""; done
	echo "verilog work \"$RTL/main.v\""
} > fit.prj

cat > fit.xst <<EOF
set -tmpdir "xst/projnav.tmp"
set -xsthdpdir "xst"
run
-ifn fit.prj
-ifmt mixed
-ofn fit
-ofmt NGC
-p xc6slx25-2-ftg256
-top $TOP
-opt_mode $MODE
-opt_level $LEVEL
-iobuf NO
-keep_hierarchy Soft
-shreg_extract YES
EOF
if [ -n "$XCF" ]; then echo "-uc $FIT/$XCF" >> fit.xst; fi
if [ "$TOP" = main ]; then
	echo "-generics {USE_DLH=1 USE_CX4=0 USE_SDD1=0 USE_GSU=0 USE_SA1=0 USE_DSPn=$DSPN USE_SPC7110=0 USE_BSX=0 USE_SUFAMI=0 USE_MSU=0 USE_SS=0}" >> fit.xst
fi

set -- # settings64.sh takes the arguments of the script that sources it: none
source "$ISE_SETTINGS" > /dev/null
xst -intstyle ise -ifn fit.xst -ofn fit.syr > /dev/null || { grep ERROR fit.syr; exit 1; }
echo "$TOP ($MODE, DSPn $DSPN):"
grep -E "Number of Slice (LUTs|Registers):|Number of Block RAM/FIFO:|Number of DSP48A1s:|Minimum period" fit.syr
