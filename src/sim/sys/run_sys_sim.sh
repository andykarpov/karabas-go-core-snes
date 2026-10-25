#!/bin/bash
# Tests of the parts of snes_system (iverilog). Each test prints "<tb>: 0 errors".
#   ./run_sys_sim.sh
set -e
cd "$(dirname "$0")"
RTL=../../rtl
mkdir -p build
iverilog -g2005 -o build/tb_hdr -s tb_hdr tb_hdr.v $RTL/snes_hdr.v
vvp -n build/tb_hdr | grep -v "finish"
iverilog -g2005 -o build/tb_video -s tb_video tb_video.v $RTL/video/snes_video.v ../../../modules/rtl/mem/kg_sdpram.v
vvp -n build/tb_video | grep -v "finish"
