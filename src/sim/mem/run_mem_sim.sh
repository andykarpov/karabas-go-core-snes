#!/bin/bash
# The memory controllers against models of the SRAM and SDRAM (iverilog). Each test prints
# "<tb>: 0 errors".
#   ./run_mem_sim.sh
set -e
cd "$(dirname "$0")"
RTL=../../rtl
UNISIMS=${XILINX:-/opt/Xilinx/14.7/ISE_DS/ISE}/verilog/src
mkdir -p build
# The SDRAM with the delays of the board: T_OUT from the FPGA registers to the SDRAM (SDR_CLK,
# commands, write data), T_IN from the SDRAM back to the IOB registers. With RD_DELAY 4 the read
# data are taken in the window D = T_OUT + T_IN from 3.2 to 11.5 ns (see snes_sdram.v); the
# estimate of the board is 5.5 ns. Inside: 3.5, 5.5, 11.0; outside (the test must fail): 2.5, 12.5.
sdram() {
	iverilog -g2005 -o build/tb_sdram -s tb_sdram -s glbl -Ptb_sdram.T_OUT=$1 -Ptb_sdram.T_IN=$2 \
		-Ptb_sdram.N=$3 tb_sdram.v sdram_model.v $RTL/mem/snes_sdram.v $RTL/mem/snes_phase.v \
		$UNISIMS/unisims/ODDR2.v $UNISIMS/glbl.v
	vvp -n build/tb_sdram | grep "^tb_sdram"
}
for d in "2.5 1.0" "4.0 1.5" "8.0 3.0"; do sdram $d 20000; done
echo "outside the window, errors expected:"
for d in "2.0 0.5" "9.0 3.5"; do sdram $d 1000 | grep errors; done
# the SRAM: the delays of the ucf budget (12 ns out, 12 ns in, the access takes the data 34.9 ns
# after the address: 12 + 10 + 12 = 34 fits) and smaller ones; beyond it the test must fail
sram() {
	iverilog -g2005 -o build/tb_sram -s tb_sram -Ptb_sram.T_OUT=$1 -Ptb_sram.T_IN=$2 -Ptb_sram.N=$3 \
		tb_sram.v $RTL/mem/snes_sram.v $RTL/mem/snes_phase.v
	vvp -n build/tb_sram | grep "^tb_sram"
}
for d in "3.0 2.0" "6.0 4.0" "12.0 12.0"; do sram $d 5000; done
echo "outside the budget, errors expected:"
sram 14.0 12.0 500 | grep errors
