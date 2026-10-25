#!/bin/bash
# Equivalence tests of the karabas changes to upstream code against the upstream versions in
# ref/ (ghdl). Each test prints "<tb>: 0 errors".
#   ./run_eq.sh
set -e
cd "$(dirname "$0")"
RTL=../../rtl/snes
W=build
rm -rf $W; mkdir -p $W
G="ghdl -a --std=08 -fsynopsys --workdir=$W"
$G $RTL/65C816/P65816_pkg.vhd $RTL/65C816/MCode.vhd ref/MCode_ref.vhd
$G $RTL/SPC700/SPC700_pkg.vhd $RTL/SPC700/MCode.vhd ref/SPC700_MCode_ref.vhd
$G tb_eq_mcode.vhd
# the don't care words of the tables index ALU_TAB with X: no metavalue warnings
ghdl -r --std=08 -fsynopsys --workdir=$W tb_eq_mcode --ieee-asserts=disable 2>&1 | grep -E "errors|differs" | sed 's/^.*(report [a-z]*): //'
