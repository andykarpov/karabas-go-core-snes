`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_phase.v

 The phase of clk_mem against clk_sys, both of one PLL with clk_mem = 4 x clk_sys and phase 0:
 ph = 0 at the clk_mem edge that is a rising clk_sys edge (the edge at which the memory
 controllers change their answers). A toggle of clk_sys is taken by clk_mem; the edge after
 the one that sees it change is ph 2, so ph follows from it. ph is valid 3 clk_mem after the
 first clk_sys edges.
*/

module snes_phase (
	input wire clk_sys,
	input wire clk_mem,
	output reg [1:0] ph = 2'd0
);

reg t = 1'b0;
always @(posedge clk_sys) t <= ~t;

// t changes after the clk_mem edge of ph 0: the edge of ph 1 takes the new value into s,
// the edge of ph 2 sees s != s_d
reg s = 1'b0, s_d = 1'b0;
always @(posedge clk_mem) begin
	s <= t;
	s_d <= s;
	if (s != s_d)
		ph <= 2'd3;
	else
		ph <= ph + 2'd1;
end

endmodule
