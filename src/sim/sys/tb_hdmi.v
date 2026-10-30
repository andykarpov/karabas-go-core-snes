`timescale 1ns / 1ps

// snes_hdmi with clk_pix of NTSC (25.21 MHz) and of PAL (27.27 MHz), the video timing of snes_video
// (lines of 800 clk, HS 96, DE 640 from clk 144; PAL 864, HS 64, DE 720 from 132; every 7th line 5 clk
// longer as in the lock), short frames of 40 lines (VS lines 0..1, DE lines 6..35), a pattern of
// colour; the sound of the DSP on clk_sys (21.429 MHz): a sample each 671 or 672 clk (31.9 kHz), lrck
// high in its first half, the sample (a sequence the test knows) changing at the rising edge.
// The output is decoded word by word, each against the input 11 clk before (the delay of the video
// and the encoder): in DE the pixel (TMDS decoded); the 10 clk before DE the video preamble (CTL 1000,
// 8 clk) and the video guard band; the rest control words with the syncs (negative), or a data island:
// preamble (CTL 1010, 8), guard band (2), packets of 32 clk (TERC4, the syncs in channel 0, bit 3 0
// only in the first clk), guard band (2), one island a line. Each packet: the ECC of the header and
// of the 4 subpackets; ACR: N 4096, the 4 subpackets the same, CTS = clk_pix of 32 samples (+-3);
// AVI InfoFrame: checksum, version 2, VIC 1 (PAL 17); Audio InfoFrame: checksum; Audio Sample: each
// sample the next of the sequence (none lost or doubled), its parity bits, the channel status bit
// and B (start of a block of 192). In the end all samples but the last few came out.
// Phases: NTSC, PAL, dvi_only (plain DVI: no island, no preamble, no guard band).

module tb_hdmi;

parameter real T_SYS = 46.667;
parameter real T_NTSC = 46.667 * 34.0 / 40.0;
parameter real T_PAL = 46.667 * 22.0 / 28.0;

reg pal_mode = 1'b0, dvi_only = 1'b0;
real t_pix = T_NTSC;
always @(pal_mode) t_pix = pal_mode ? T_PAL : T_NTSC;

reg clk_sys = 1'b0, clk_pix = 1'b0;
always #(T_SYS / 2) clk_sys = ~clk_sys;
always #(t_pix / 2) clk_pix = ~clk_pix;

integer errors = 0;
task fail;
	input [8*40-1:0] what;
	input integer v;
	begin
		errors = errors + 1;
		if (errors <= 20) $display("tb_hdmi: %0t: %0s %0d", $time, what, v);
	end
endtask

// ---- the sound: sample k
function [15:0] smp_l;
	input integer k;
	smp_l = k * 37 + 1;
endfunction
function [15:0] smp_r;
	input integer k;
	smp_r = ~(k * 1031) ^ 16'h5A5A;
endfunction

reg [15:0] audio_l = 16'd0, audio_r = 16'd0;
reg lrck = 1'b0;
integer sc = 0, sper = 671, nsmp = 0;       // nsmp: samples made
always @(posedge clk_sys) begin
	sc = sc + 1;
	if (sc == sper) begin
		sc = 0;
		sper = (nsmp % 3 == 0) ? 672 : 671;
		lrck <= 1'b1;
		audio_l <= smp_l(nsmp);
		audio_r <= smp_r(nsmp);
		nsmp = nsmp + 1;
	end
	if (sc == sper / 2) lrck <= 1'b0;
end

// ---- the video
reg [23:0] rgb = 24'd0;
reg hs = 1'b0, vs = 1'b0, de = 1'b0;
integer hc = 0, ln = 0, lines = 0;
wire [9:0] ht = pal_mode ? 10'd864 : 10'd800;
always @(negedge clk_pix) begin
	hc = hc + 1;
	if (hc >= ht + ((ln % 7 == 3) ? 5 : 0)) begin
		hc = 0;
		ln = (ln + 1) % 40;
		lines = lines + 1;
	end
	hs <= hc < (pal_mode ? 64 : 96);
	vs <= ln < 2;
	de <= ln >= 6 && ln < 36 && hc >= (pal_mode ? 132 : 144) && hc < (pal_mode ? 852 : 784);
	rgb <= {hc[7:0], ln[7:0] ^ 8'h3C, hc[9:2] + ln[7:0]};
end

wire [9:0] t_r, t_g, t_b;
snes_hdmi dut(
	.clk_pix(clk_pix), .pal(pal_mode), .dvi_only(dvi_only),
	.rgb(rgb), .hs(hs), .vs(vs), .de(de),
	.audio_l(audio_l), .audio_r(audio_r), .lrck(lrck),
	.tmds_r(t_r), .tmds_g(t_g), .tmds_b(t_b)
);

// ---- the decoder
localparam [9:0] VGB0 = 10'b1011001100, VGB1 = 10'b0100110011, DGB = 10'b0100110011;

function [9:0] ctrl;
	input [1:0] c;
	case (c)
		2'b00: ctrl = 10'b1101010100;
		2'b01: ctrl = 10'b0010101011;
		2'b10: ctrl = 10'b0101010100;
		default: ctrl = 10'b1010101011;
	endcase
endfunction

reg [9:0] terc [0:15];
initial begin
	terc[0] = 10'b1010011100; terc[1] = 10'b1001100011; terc[2] = 10'b1011100100; terc[3] = 10'b1011100010;
	terc[4] = 10'b0101110001; terc[5] = 10'b0100011110; terc[6] = 10'b0110001110; terc[7] = 10'b0100111100;
	terc[8] = 10'b1011001100; terc[9] = 10'b0100111001; terc[10] = 10'b0110011100; terc[11] = 10'b1011000110;
	terc[12] = 10'b1010001110; terc[13] = 10'b1001110001; terc[14] = 10'b0101100011; terc[15] = 10'b1011000011;
end
function [4:0] unterc;                       // {invalid, d}
	input [9:0] w;
	integer j;
	begin
		unterc = 5'h10;
		for (j = 0; j < 16; j = j + 1) if (terc[j] == w) unterc = j;
	end
endfunction

function [7:0] untmds;
	input [9:0] q;
	reg [7:0] m;
	integer j;
	begin
		m = q[9] ? ~q[7:0] : q[7:0];
		untmds[0] = m[0];
		for (j = 1; j < 8; j = j + 1) untmds[j] = q[8] ? m[j] ^ m[j-1] : ~(m[j] ^ m[j-1]);
	end
endfunction

function [7:0] ecc_bits;                     // BCH of HDMI over n bits of v, bit 0 first
	input [63:0] v;
	input integer n;
	reg [7:0] e;
	integer j;
	begin
		e = 0;
		for (j = 0; j < n; j = j + 1) e = {e[6:0], 1'b0} ^ ((e[7] ^ v[j]) ? 8'hC1 : 8'h00);
		// the ECC goes out e[7] first: as bits n..n+7 of the packet
		for (j = 0; j < 8; j = j + 1) ecc_bits[j] = e[7 - j];
	end
endfunction

// the input history: hist[p % 64] the input at the rising edge p
reg [26:0] hist [0:63];
integer p = 0;
always @(posedge clk_pix) begin
	p = p + 1;
	hist[p % 64] = {rgb, hs, vs, de};
end

integer st = 0;                              // island: 0 none, 1 preamble, 2 guard, 3 packets, 4 trailing guard
integer cnt = 0, pk_clk = 0, pkts = 0, isl_line = 0, line_isl = 0;
reg [31:0] hdr;
reg [63:0] sub [0:3];
reg first_clk;
integer n_acr = 0, n_avi = 0, n_aif = 0, n_aud = 0, n_null = 0, n_vid = 0, n_islands = 0;
integer next_k = -1, got = 0, cs_k = -1, acr_skip = 0;
integer phase = 0;
real exp_cts;

// the CH_STATUS bit of frame i: 32 kHz, 16 bits, no copyright (bits 2, 14, 24, 25, 33, 38, 39)
function cs_exp;
	input integer i;
	cs_exp = i == 2 || i == 14 || i == 24 || i == 25 || i == 33 || i == 38 || i == 39;
endfunction

task packet;
	integer j, s, k;
	reg [7:0] cksum;
	reg [15:0] l, r;
	begin
		pkts = pkts + 1;
		if (hdr[31:24] != ecc_bits({40'd0, hdr[23:0]}, 24)) fail("header ECC of type", hdr[7:0]);
		for (j = 0; j < 4; j = j + 1)
			if (sub[j][63:56] != ecc_bits({8'd0, sub[j][55:0]}, 56)) fail("subpacket ECC, type", hdr[7:0]);
		cksum = 0;
		for (j = 0; j < 3; j = j + 1) cksum = cksum + hdr[8*j +: 8];
		for (j = 0; j < 7; j = j + 1) cksum = cksum + sub[0][8*j +: 8] + sub[1][8*j +: 8];
		case (hdr[7:0])
			8'h00: n_null = n_null + 1;
			8'h01: begin
				n_acr = n_acr + 1;
				if (sub[0][55:0] != sub[1][55:0] || sub[0][55:0] != sub[2][55:0] || sub[0][55:0] != sub[3][55:0])
					fail("ACR subpackets differ", 0);
				if ({sub[0][35:32], sub[0][47:40], sub[0][55:48]} != 20'd4096) fail("ACR N", 0);
				exp_cts = (pal_mode ? T_SYS * 671.333 / T_PAL : T_SYS * 671.333 / T_NTSC) * 32.0;
				k = {sub[0][11:8], sub[0][23:16], sub[0][31:24]};
				if (acr_skip > 0) acr_skip = acr_skip - 1;
				else if (k < exp_cts - 3.0 || k > exp_cts + 3.0) fail("ACR CTS", k);   // 10 or 11 periods of 672 in 32, sync
			end
			8'h82: begin
				n_avi = n_avi + 1;
				if (hdr[23:8] != 16'h0D02 || cksum != 0) fail("AVI header / checksum", cksum);
				if (sub[0][39:32] != (pal_mode ? 8'd17 : 8'd1)) fail("AVI VIC", sub[0][39:32]);
			end
			8'h84: begin
				n_aif = n_aif + 1;
				if (hdr[23:8] != 16'h0A01 || cksum != 0) fail("Audio InfoFrame header / checksum", cksum);
			end
			8'h02: begin
				n_aud = n_aud + 1;
				if (hdr[11:8] != 4'b0001 && hdr[11:8] != 4'b0011) fail("audio samples present", hdr[11:8]);
				for (s = 0; s < 2; s = s + 1) if (hdr[8 + s]) begin
					l = sub[s][23:8]; r = sub[s][47:32];
					if (next_k < 0) begin             // the first: find it in the sequence
						for (k = 0; k < nsmp; k = k + 1) if (smp_l(k) == l && smp_r(k) == r) next_k = k;
						if (next_k < 0) fail("first sample unknown", l);
					end
					if (next_k >= 0) begin
						if (l != smp_l(next_k) || r != smp_r(next_k)) fail("sample, expected number", next_k);
						next_k = next_k + 1;
					end
					got = got + 1;
					if (sub[s][51] != (^l ^ sub[s][50] ^ sub[s][49] ^ sub[s][48])) fail("parity left", got);
					if (sub[s][55] != (^r ^ sub[s][54] ^ sub[s][53] ^ sub[s][52])) fail("parity right", got);
					if (sub[s][50] != sub[s][54]) fail("channel status L / R", got);
					if (hdr[20 + s]) cs_k = 0;           // B: frame 0 of the block
					else if (cs_k >= 0) cs_k = cs_k + 1;
					if (cs_k >= 192) fail("no B after 192 frames", cs_k);
					if (cs_k >= 0 && sub[s][50] != cs_exp(cs_k)) fail("channel status bit, frame", cs_k);
				end
			end
			default: fail("packet type", hdr[7:0]);
		endcase
	end
endtask

reg [26:0] e;
reg [9:0] w0, w1, w2;
reg [4:0] d0, d1, d2;
integer j, dist, ph;
always @(negedge clk_pix) if (p > 1000) begin    // after the island of line 1
	e = hist[(p - 11) % 64];
	w0 = t_b; w1 = t_g; w2 = t_r;
	// the distance to the next DE of the input (1..10), else 0
	dist = 0;
	for (j = 10; j >= 1; j = j - 1) if (hist[(p - 11 + j) % 64][0] && !hist[(p - 12 + j) % 64][0]) dist = j;
	d0 = unterc(w0); d1 = unterc(w1); d2 = unterc(w2);
	if (e[0]) begin                          // DE
		n_vid = n_vid + 1;
		if (st != 0) fail("island into DE", st);
		if ({untmds(w2), untmds(w1), untmds(w0)} != e[26:3]) fail("pixel", p);
	end else if (dist >= 1 && dist <= 2 && !dvi_only) begin
		if (w0 != VGB0 || w1 != VGB1 || w2 != VGB0) fail("video guard band", dist);
	end else if (dist >= 3 && !dvi_only) begin
		if (w0 != ctrl({~e[1], ~e[2]}) || w1 != ctrl(2'b01) || w2 != ctrl(2'b00)) fail("video preamble", dist);
		if (st != 0) fail("island into the video preamble", st);
	end else begin
		// control or an island
		case (st)
			0: if (w0 == ctrl({~e[1], ~e[2]}) && w1 == ctrl(2'b01) && w2 == ctrl(2'b01)) begin
					st = 1; cnt = 1;
				end else if (w0 != ctrl({~e[1], ~e[2]}) || w1 != ctrl(2'b00) || w2 != ctrl(2'b00))
					fail("control word", p);
			1: if (w0 == ctrl({~e[1], ~e[2]}) && w1 == ctrl(2'b01) && w2 == ctrl(2'b01)) cnt = cnt + 1;
				else begin
					if (cnt != 8) fail("data island preamble length", cnt);
					st = 2; cnt = 0;
				end
			default: ;
		endcase
		if (st == 2 || st == 4) begin
			if (d0[4] || d0[3:0] != {2'b11, ~e[1], ~e[2]} || w1 != DGB || w2 != DGB) begin
				if (st == 2 && cnt == 2) begin       // the packets start
					st = 3; pk_clk = 0; first_clk = 1;
				end else if (st == 4 && cnt == 2) begin
					st = 0; n_islands = n_islands + 1; line_isl = line_isl + 1;
					if (pkts != 2) fail("packets in the island", pkts);
					if (w0 != ctrl({~e[1], ~e[2]}) || w1 != ctrl(2'b00) || w2 != ctrl(2'b00))
						fail("control after the island", p);
				end else fail("guard band", st * 10 + cnt);
			end else cnt = cnt + 1;
		end
		if (st == 3) begin
			if (d0[4] || d1[4] || d2[4]) begin
				if (pk_clk == 0 && w1 == DGB && w2 == DGB) begin st = 4; cnt = 1; end
				else fail("not TERC4 in a packet", pk_clk);
			end else begin
				if (pk_clk == 0) begin hdr = 0; for (j = 0; j < 4; j = j + 1) sub[j] = 0; end
				if (d0[1:0] != {~e[1], ~e[2]}) fail("syncs in the island", p);
				if (d0[3] != !first_clk) fail("bit 3 of channel 0", pk_clk);
				first_clk = 0;
				hdr[pk_clk] = d0[2];
				for (j = 0; j < 4; j = j + 1) begin
					sub[j][2 * pk_clk] = d1[j];
					sub[j][2 * pk_clk + 1] = d2[j];
				end
				pk_clk = pk_clk + 1;
				if (pk_clk == 32) begin packet; pk_clk = 0; end
			end
		end
	end
	if (st == 1 && cnt == 1) pkts = 0;
end

// one island a line (HDMI), none (DVI)
reg hs_q = 1'b0;
always @(posedge clk_pix) begin
	hs_q <= hs;
	if (hs && !hs_q) begin
		if (lines > 3 && line_isl != (dvi_only ? 0 : 1) && phase != 99) fail("islands in a line", line_isl);
		line_isl = 0;
	end
end

initial begin
	acr_skip = 1;
	wait (lines == 1500);
	$display("tb_hdmi: NTSC: %0d islands, ACR %0d, AVI %0d, AIF %0d, audio %0d, null %0d, samples %0d of %0d",
		n_islands, n_acr, n_avi, n_aif, n_aud, n_null, got, nsmp);
	if (n_acr < 40 || n_avi < 500 || n_aif < 500 || n_vid < 100000) fail("NTSC: few packets", n_acr);
	// PAL: the mode at a line start, as the tops switch clk_pix
	wait (hc == 0);
	phase = 99; pal_mode = 1'b1; acr_skip = 2;
	wait (lines == 1503); phase = 1;
	wait (lines == 2600);
	$display("tb_hdmi: PAL: %0d islands, ACR %0d, AVI %0d, AIF %0d, audio %0d, null %0d, samples %0d of %0d",
		n_islands, n_acr, n_avi, n_aif, n_aud, n_null, got, nsmp);
	if (nsmp - next_k > 3 || nsmp - next_k < 0) fail("samples not sent", nsmp - next_k);
	// DVI
	wait (hc == 0);
	phase = 99; dvi_only = 1'b1;
	wait (lines == 2603); phase = 2;
	isl_line = n_islands;
	wait (lines == 2700);
	if (n_islands != isl_line) fail("islands in DVI", n_islands - isl_line);
	$display("tb_hdmi: %0d errors", errors);
	$finish;
end

endmodule
