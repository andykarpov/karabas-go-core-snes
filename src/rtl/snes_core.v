`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_core.v

 The part of the three tops that does not depend on the board: the soft switches of the OSD,
 the joysticks, the SNES (snes_system), the 31 kHz video (snes_video) and the OSD overlay. The
 tops add the clocks, the MCU link and the outputs (DVI, VGA, the DACs).

 Soft switches: the osd items of core*.json in their order, register n = item n:
   0 ROM type (Auto, LoROM, HiROM, ExHiROM), 1 Region (Auto, NTSC, PAL), 2 Swap joysticks,
   3 Reset (the last item).

 Joysticks: kg_mcu bits (karabas-go-firmware docs/protocol.md): 1 up, 2 down, 3 left, 4 right,
 5 start, 6 A, 7 B, 8 C, 9 X, 10 Y, 11 Z, 12 mode. SNES (snes_joy order): B = A, Y = X,
 Select = mode, Start = start, the directions, A = B, X = Y, L = C, R = Z.

 Video out: 640 x 480 window of 682 x 524 at clk_sys, rgb with the OSD; hs / vs active high,
 hs, vs, de and rgb in the same clk.
*/

module snes_core #(
	parameter USE_DSPN = 1
) (
	input wire clk_sys,
	input wire clk_mem,
	input wire areset,

	// kg_mcu
	input wire [15:0] softsw_command,
	input wire [15:0] osd_command,
	input wire mcu_busy,
	input wire [12:0] joy_l,
	input wire [12:0] joy_r,
	input wire load_active,
	input wire [31:0] load_addr,
	input wire [7:0] load_data,
	input wire load_wr,

	output wire [23:0] rgb,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0,
	output wire [15:0] audio_l,
	output wire [15:0] audio_r,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire SDR_CLK,
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire [1:0] SDR_DQM,
	output wire SDR_RAS_N,
	output wire SDR_CAS_N,
	output wire SDR_WE_N,
	inout wire [15:0] SDR_DQ
);

wire [31:0] softsw_regs;
kg_soft_switches #(.N(4)) soft_switches(
	.clk(clk_sys),
	.command(softsw_command),
	.regs(softsw_regs),
	.upd()
);
wire [1:0] rom_sel = softsw_regs[1:0];
wire [1:0] region_sel = softsw_regs[9:8];
wire joy_swap = softsw_regs[16];
wire osd_reset = softsw_regs[24];

function [11:0] snes_pad;
	input [12:0] j;
	begin
		snes_pad = {j[11], j[8], j[10], j[7], j[4], j[3], j[2], j[1], j[5], j[12], j[9], j[6]};
	end
endfunction
wire [11:0] pad1 = snes_pad(joy_swap ? joy_r : joy_l);
wire [11:0] pad2 = snes_pad(joy_swap ? joy_l : joy_r);

wire [7:0] snes_r, snes_g, snes_b;
wire snes_hs, snes_vs, snes_hblank_n, snes_vblank_n;

snes_system #(.USE_DSPN(USE_DSPN)) snes(
	.clk_sys(clk_sys),
	.clk_mem(clk_mem),
	.reset(osd_reset | mcu_busy | areset),
	.rom_sel(rom_sel),
	.region_sel(region_sel),
	.load_active(load_active),
	.load_addr(load_addr),
	.load_data(load_data),
	.load_wr(load_wr),
	.pad1(pad1),
	.pad2(pad2),
	.R(snes_r),
	.G(snes_g),
	.B(snes_b),
	.HSYNC(snes_hs),
	.VSYNC(snes_vs),
	.HBLANKn(snes_hblank_n),
	.VBLANKn(snes_vblank_n),
	.pal(),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.running(),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N),
	.MRD_N(MRD_N),
	.SDR_CLK(SDR_CLK),
	.SDR_BA(SDR_BA),
	.SDR_A(SDR_A),
	.SDR_DQM(SDR_DQM),
	.SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N),
	.SDR_WE_N(SDR_WE_N),
	.SDR_DQ(SDR_DQ)
);

wire [7:0] v_r, v_g, v_b;
wire v_hs, v_vs, v_de;
snes_video video(
	.clk(clk_sys),
	.r_in(snes_r), .g_in(snes_g), .b_in(snes_b),
	.hsync_in(snes_hs), .vsync_in(snes_vs), .hblank_n(snes_hblank_n), .vblank_n(snes_vblank_n),
	.r(v_r), .g(v_g), .b(v_b), .hs(v_hs), .vs(v_vs), .de(v_de)
);

kg_osd_overlay osd(
	.clk(clk_sys),
	.rgb_i({v_r, v_g, v_b}),
	.rgb_o(rgb),
	.hsync_i(v_hs),
	.vsync_i(v_vs),
	.osd_command(osd_command)
);

// the overlay is one clk late: the syncs and DE with it
always @(posedge clk_sys) begin
	hs <= v_hs;
	vs <= v_vs;
	de <= v_de;
end

endmodule
