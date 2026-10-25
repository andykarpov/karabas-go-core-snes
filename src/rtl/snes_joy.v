`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_joy.v

 A standard SNES controller on a port of main (JOY*_DI / JOY_STRB / JOY*_CLK), in place of
 ioport.sv of SNES_MiSTer (SystemVerilog; no multitap, mouse and rumble here).

 pad: the buttons, 1 = pressed, in the order the controller sends them:
   0 B, 1 Y, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right, 8 A, 9 X, 10 L, 11 R
 The latch (strobe high) loads them, a rising edge of the port clock shifts the next one out; the
 data line is low for a pressed button, the 4 bits after the 12 are 1 (released), then 0, as
 ioport.sv does (it shifts zeros in). DO[1] is 1: no second controller on the port (no multitap).
*/

module snes_joy (
	input wire clk,
	input wire [11:0] pad,
	input wire strobe,
	input wire port_clk,
	output wire [1:0] port_do
);

reg [15:0] sr = 16'hFFFF;
reg clk_d = 1'b0;

always @(posedge clk) begin
	clk_d <= port_clk;
	if (strobe)
		sr <= ~{pad[0], pad[1], pad[2], pad[3], pad[4], pad[5], pad[6], pad[7],
		        pad[8], pad[9], pad[10], pad[11], 4'b0000};
	else if (port_clk && !clk_d)
		sr <= {sr[14:0], 1'b0};
end

assign port_do = {1'b1, sr[15]};

endmodule
