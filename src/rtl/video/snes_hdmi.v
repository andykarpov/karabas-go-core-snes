`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_hdmi.v

 HDMI of the 31 kHz picture (snes_video with the OSD) with the sound of the SNES: the three TMDS words
 for the serialisers, on clk_pix. A small encoder of its own: hdmi_tx of zhdmi is 2240 LUTs and does
 not fit; the one of the nes core (hdmidataencoder, A. Spirkov after C. Cole) resamples to 48 kHz by
 holding a value and has CTS fixed for one pixel clock. Its ECC, TERC4 and channel status are taken.

 - Video: the input (rgb, hs, vs, de, active high) is delayed by 11 clk, so the video preamble (8 clk)
   and the video guard band (2 clk) go before each active line: a rising de seen at the input starts
   them. The syncs go out negative (640 x 480 and 576p both).
 - A data island after each leading edge of hs (of the delayed timing: clk 4..76 of the line, DE starts
   at 144, PAL 132): preamble 8, guard band 2, two packets of 32 clk, guard band 2.
   Packet 0: Audio Clock Regeneration once a new CTS is measured (each 32 samples), else the AVI and
   the Audio InfoFrame in turn. AVI: RGB full range (Q = 2), 4:3, VIC 1 (640 x 480) or 17 (576p of
   PAL), so a scaler knows the mode. Packet 1: Audio Sample with the samples that came since the last
   line (0..2; none: a null packet).
 - Sound: the samples of the DSP as they are, about 32 kHz (the DSP makes 32 kHz of 24.576 MHz by a
   fractional enable from clk_sys: 31.93 kHz on 21.43 MHz). lrck (clk_sys) changes the sample in its
   rising half; its falling edge, two flip-flops into clk_pix, takes audio_l / audio_r in the middle
   of the sample. N = 4096 (32 kHz), CTS = clk_pix of 32 samples, counted: the sink makes the clock
   of the samples from it, whatever the rate is. Channel status: 32 kHz, 16 bits.
 - dvi_only (kg_mcu, the setting of the firmware): plain DVI, no preambles, guard bands, islands.
 Output: tmds_r / g / b, registers of clk_pix (the select of the words too), one clk after the encoders.
 The TMDS encoder of the video (snes_tmds below) is dvi_encoder.vhd of the modules (MVV) in Verilog, so
 the whole of it runs in iverilog (sim/sys/tb_hdmi.v).
*/

module snes_hdmi (
	input wire clk_pix,
	input wire pal,                // clk_sys: 576p of PAL (VIC 17), else 640 x 480 (VIC 1)
	input wire dvi_only,           // clk_sys

	input wire [23:0] rgb,         // r, g, b
	input wire hs,
	input wire vs,
	input wire de,

	input wire [15:0] audio_l,     // clk_sys, held for a sample
	input wire [15:0] audio_r,
	input wire lrck,               // clk_sys, one period per sample

	output wire [9:0] tmds_r,
	output wire [9:0] tmds_g,
	output wire [9:0] tmds_b
);

wire pal_p, dvi_p, lrck_p;
kg_sync #(.W(3)) sync(.clk(clk_pix), .d({pal, dvi_only, lrck}), .q({pal_p, dvi_p, lrck_p}));

// ---- the delay of the video
reg [26:0] dl [0:10];
integer i;
always @(posedge clk_pix) begin
	dl[0] <= {rgb, hs, vs, de};
	for (i = 1; i < 11; i = i + 1) dl[i] <= dl[i-1];
end
wire [23:0] d_rgb = dl[10][26:3];
wire d_hs = dl[10][2], d_vs = dl[10][1], d_de = dl[10][0];
wire hs_n = ~d_hs, vs_n = ~d_vs;    // on the wire

// ---- the samples: a queue of two, each the subpacket of a sample with its B (start of block) bit
reg lrck_d = 1'b0;
reg take = 1'b0, push = 1'b0;
reg [15:0] al = 16'd0, ar = 16'd0;
reg [7:0] cs_idx = 8'd0;               // the frame of the 192 of channel status
reg [56:0] q0 = 57'd0, q1 = 57'd0;
reg [1:0] qn = 2'd0;
reg [4:0] scnt = 5'd0;                 // samples, for CTS
reg [16:0] pcnt = 17'd0, cts = 17'd0;
reg acr_req = 1'b0;
wire pop;
reg [6:0] ic = 7'd0;                   // the island: 1..8 preamble, 9..10 guard, 11..74 packets, 75..76 guard
wire load0 = ic == 7'd10;           // packet 0 into the shift registers
wire load1 = ic == 7'd42;           // packet 1
wire acr_load = load0 & acr_req;
assign pop = load1;

// IEC 60958 channel status, bits 0..39 (the rest 0): no copyright, 32 kHz, 16 bits
localparam [63:0] CH_STATUS = 64'h000000C203004004;
wire cs_bit = (cs_idx[7:6] == 2'd0) && CH_STATUS[cs_idx[5:0]];
// bits 0..7 0, 8..23 left, 32..47 right, 48 V, 49 U, 50 C, 51 P of left, 52..55 of right; P: even parity of
// the sample and V, U, C
wire [56:0] sw = {cs_idx == 8'd0, ^ar ^ cs_bit, cs_bit, 2'b00, ^al ^ cs_bit, cs_bit, 2'b00,
	ar, 8'h00, al, 8'h00};

always @(posedge clk_pix) begin
	lrck_d <= lrck_p;
	take <= lrck_d & ~lrck_p;
	if (take) begin
		al <= audio_l;
		ar <= audio_r;
	end
	push <= take;

	if (pop) begin
		qn <= push ? 2'd1 : 2'd0;
		if (push) q0 <= sw;
	end else if (push) begin
		if (qn == 2'd0) q0 <= sw;
		if (qn == 2'd1) q1 <= sw;
		if (qn != 2'd2) qn <= qn + 2'd1;   // a third one is lost (more than 2 samples a line do not come)
	end
	if (push) cs_idx <= cs_idx == 8'd191 ? 8'd0 : cs_idx + 8'd1;

	if (push && scnt == 5'd31) begin
		cts <= pcnt;
		pcnt <= 17'd1;
		acr_req <= 1'b1;
	end else
		pcnt <= pcnt + 17'd1;
	if (push) scnt <= scnt + 5'd1;
	if (acr_load) acr_req <= 1'b0;
end

// ---- packets
// ACR: N = 4096, CTS
wire [55:0] acr_w = {8'h00, 8'h10, 8'h00, cts[7:0], cts[15:8], 7'd0, cts[16], 8'h00};
// AVI InfoFrame v2: PB0 checksum, PB1 10 (RGB, A0), PB2 18 (4:3, as coded), PB3 08 (full range), PB4 VIC
wire [55:0] avi_w = pal_p ? 56'h00_00_11_08_18_10_2E : 56'h00_00_01_08_18_10_3E;
// Audio InfoFrame: PB0 checksum, PB1 11 (PCM, 2 channels)
localparam [55:0] AIF_W = 56'h00000000001160;

reg [3:0] vp = 4'd0;                   // the video: 1..8 preamble, 9..10 guard
reg hs_d = 1'b0, de_d = 1'b0;
reg info = 1'b0;                       // AVI / Audio InfoFrame in turn
reg acr = 1'b0;                        // packet 0 is ACR: subpackets 2, 3 as 0
reg [23:0] hsr = 24'd0;
reg [55:0] s0 = 56'd0, s1 = 56'd0;
reg [7:0] eh = 8'd0, e0 = 8'd0, e1 = 8'd0;

wire [6:0] pc = ic - 7'd11;
wire [4:0] c = pc[4:0];                // the clk in the packet
wire in_pkt = ic >= 7'd11 && ic <= 7'd74;

function [7:0] ecc1;                   // BCH of HDMI, a bit
	input [7:0] e;
	input b;
	ecc1 = {e[6:0], 1'b0} ^ ((e[7] ^ b) ? 8'hC1 : 8'h00);
endfunction

wire hbit = c < 5'd24 ? hsr[0] : eh[7];
wire [1:0] b0 = c < 5'd28 ? s0[1:0] : {e0[6], e0[7]};   // [0] channel 1: the ECC goes out bit 7 first
wire [1:0] b1 = c < 5'd28 ? s1[1:0] : {e1[6], e1[7]};
wire [1:0] b23 = acr ? b0 : 2'b00;     // ACR: all four subpackets the same

always @(posedge clk_pix) begin
	hs_d <= d_hs;
	de_d <= de;
	ic <= (d_hs && !hs_d && !dvi_p) ? 7'd1 : (ic != 7'd0 && ic != 7'd76) ? ic + 7'd1 : 7'd0;
	vp <= (de && !de_d && !dvi_p) ? 4'd1 : (vp != 4'd0 && vp != 4'd10) ? vp + 4'd1 : 4'd0;

	if (load0) begin
		acr <= acr_req;
		info <= acr_req ? info : ~info;
		hsr <= acr_req ? 24'h000001 : info ? 24'h0A0184 : 24'h0D0282;
		s0 <= acr_req ? acr_w : info ? AIF_W : avi_w;
		s1 <= acr_req ? acr_w : 56'd0;
		{eh, e0, e1} <= 24'd0;
	end else if (load1) begin
		acr <= 1'b0;
		hsr <= qn == 2'd0 ? 24'h000000 :
		       {2'b00, qn[1] & q1[56], q0[56], 4'h0, 6'd0, qn[1], 1'b1, 8'h02};
		s0 <= qn != 2'd0 ? q0[55:0] : 56'd0;
		s1 <= qn[1] ? q1[55:0] : 56'd0;
		{eh, e0, e1} <= 24'd0;
	end else if (in_pkt) begin
		eh <= c < 5'd24 ? ecc1(eh, hsr[0]) : {eh[6:0], 1'b0};
		e0 <= c < 5'd28 ? ecc1(ecc1(e0, s0[0]), s0[1]) : {e0[5:0], 2'b00};
		e1 <= c < 5'd28 ? ecc1(ecc1(e1, s1[0]), s1[1]) : {e1[5:0], 2'b00};
		hsr <= hsr >> 1;
		s0 <= s0 >> 2;
		s1 <= s1 >> 2;
	end
end

// ---- the words
function [9:0] terc4;
	input [3:0] d;
	case (d)
		4'h0: terc4 = 10'b1010011100;
		4'h1: terc4 = 10'b1001100011;
		4'h2: terc4 = 10'b1011100100;
		4'h3: terc4 = 10'b1011100010;
		4'h4: terc4 = 10'b0101110001;
		4'h5: terc4 = 10'b0100011110;
		4'h6: terc4 = 10'b0110001110;
		4'h7: terc4 = 10'b0100111100;
		4'h8: terc4 = 10'b1011001100;
		4'h9: terc4 = 10'b0100111001;
		4'hA: terc4 = 10'b0110011100;
		4'hB: terc4 = 10'b1011000110;
		4'hC: terc4 = 10'b1010001110;
		4'hD: terc4 = 10'b1001110001;
		4'hE: terc4 = 10'b0101100011;
		default: terc4 = 10'b1011000011;
	endcase
endfunction

// control periods: CTL0..3 on C of green and red; preamble of a data island 1010, of video 1000
wire pre_d = ic >= 7'd1 && ic <= 7'd8;
wire pre_v = vp >= 4'd1 && vp <= 4'd8;
wire [9:0] enc_r, enc_g, enc_b;
snes_tmds enc_blue(.clk(clk_pix), .d(d_rgb[7:0]), .c({vs_n, hs_n}), .blank(~d_de), .q(enc_b));
snes_tmds enc_green(.clk(clk_pix), .d(d_rgb[15:8]), .c({1'b0, pre_d | pre_v}), .blank(~d_de), .q(enc_g));
snes_tmds enc_red(.clk(clk_pix), .d(d_rgb[23:16]), .c({1'b0, pre_d}), .blank(~d_de), .q(enc_r));

// the island and the video guard band, in the clk of the encoders
reg own = 1'b0;
reg [9:0] w0 = 10'd0, w1 = 10'd0, w2 = 10'd0;
always @(posedge clk_pix) begin
	own <= ic >= 7'd9 || vp >= 4'd9;
	if (vp >= 4'd9) begin
		w0 <= 10'b1011001100;
		w1 <= 10'b0100110011;
		w2 <= 10'b1011001100;
	end else if (in_pkt) begin
		w0 <= terc4({ic != 7'd11, hbit, vs_n, hs_n});
		w1 <= terc4({b23[0], b23[0], b1[0], b0[0]});
		w2 <= terc4({b23[1], b23[1], b1[1], b0[1]});
	end else begin
		w0 <= terc4({2'b11, vs_n, hs_n});
		w1 <= 10'b0100110011;
		w2 <= 10'b0100110011;
	end
end

assign tmds_b = own ? w0 : enc_b;
assign tmds_g = own ? w1 : enc_g;
assign tmds_r = own ? w2 : enc_r;

endmodule

// TMDS of a video byte (DVI 1.0), the control words in blanking: dvi_encoder.vhd (MVV) of the modules, the
// running disparity in half units as there
module snes_tmds (
	input wire clk,
	input wire [7:0] d,
	input wire [1:0] c,
	input wire blank,
	output reg [9:0] q = 10'd0
);

wire [3:0] ones = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
wire xn = ones > 4'd4 || (ones == 4'd4 && !d[0]);
wire [8:0] m;
assign m[0] = d[0];
genvar k;
generate
	for (k = 1; k < 8; k = k + 1) begin : qm
		assign m[k] = xn ? ~(m[k-1] ^ d[k]) : m[k-1] ^ d[k];
	end
endgenerate
assign m[8] = ~xn;
wire [3:0] disp = 4'b1100 + m[0] + m[1] + m[2] + m[3] + m[4] + m[5] + m[6] + m[7];
reg [3:0] bias = 4'd0;

always @(posedge clk) begin
	if (blank) begin
		case (c)
			2'b00: q <= 10'b1101010100;
			2'b01: q <= 10'b0010101011;
			2'b10: q <= 10'b0101010100;
			default: q <= 10'b1010101011;
		endcase
		bias <= 4'd0;
	end else if (bias == 4'd0 || disp == 4'd0) begin
		if (m[8]) begin
			q <= {2'b01, m[7:0]};
			bias <= bias + disp;
		end else begin
			q <= {2'b10, ~m[7:0]};
			bias <= bias - disp;
		end
	end else if (bias[3] == disp[3]) begin
		q <= {1'b1, m[8], ~m[7:0]};
		bias <= bias + m[8] - disp;
	end else begin
		q <= {1'b0, m};
		bias <= bias - !m[8] + disp;
	end
end

endmodule
