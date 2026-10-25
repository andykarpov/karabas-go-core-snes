`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_video.v

 The 15 kHz picture of main as 640 x 480 at 60 Hz with the timing of VESA / CEA 640 x 480 (HS 96,
 back porch 48, 640 active, front porch 16 = 800 clk; VS 2 lines, back porch 33, 480 active),
 on its own pixel clock clk_pix = clk_sys x 27 / 23 (25.16 MHz, a DCM of the top). The first
 version used clk_sys (21.4 MHz) as the pixel clock with 682 clk lines: below the 25 MHz of
 DVI, and some monitors showed nothing.

 Each line of the SNES (1364 clk_sys, 1360 the short one) is written into a line buffer, one
 sample per 2 clk_sys (682 samples: a dot of 256 is two samples, of 512 one), and is read out as
 two output lines during the next SNES line, one sample per output pixel. The output lines are
 locked to the SNES lines: a SNES line starts output line A (800 clk), line B lasts until the
 next SNES line (1364 x 27 / 23 = 1601 clk_pix: 801 clk, 797 for the short line). The picture is
 the 512 samples from the first active sample of the line, at x 64 of the window (black
 outside), so 512 x 448 (478 PAL) in the middle of 640 x 480. A frame has 2 x 262 = 524 lines
 (PAL 624), the window starts 16 lines before the first active line.

 The line buffer has a port in each clock (no path between them through it). A new SNES line
 crosses as a toggle (two clk_pix flip-flops); the line number of the buffer and the frame flags
 of that line are registers of clk_sys that hold for the whole line, taken at the toggle.
 Outputs: rgb, hs, vs (active high), de, all registers of clk_pix in the same clk.
*/

module snes_video (
	input wire clk_sys,
	input wire clk_pix,

	input wire [7:0] r_in,
	input wire [7:0] g_in,
	input wire [7:0] b_in,
	input wire hsync_in,       // active high, from main
	input wire hblank_n,
	input wire vblank_n,

	output reg [7:0] r = 8'd0,
	output reg [7:0] g = 8'd0,
	output reg [7:0] b = 8'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0
);

// ---- clk_sys: the line buffer
reg hs_d = 1'b0, hb_d = 1'b0;
reg wsel = 1'b0;               // the line being written
reg half = 1'b0;               // the sample phase (a sample per 2 clk)
reg [9:0] wx = 10'd0;
reg [9:0] act_x_w = 10'd100;   // the first active sample of the line being written
reg vb_line = 1'b0, vb_prev = 1'b0;

// of the last complete line, held during the next one
reg line_tgl = 1'b0;
reg l_sel = 1'b0;
reg [9:0] l_act_x = 10'd100;
reg l_first = 1'b0;            // the first active line of a frame

wire new_line = hsync_in && !hs_d;

always @(posedge clk_sys) begin
	hs_d <= hsync_in;
	hb_d <= hblank_n;
	half <= ~half;
	if (new_line) begin
		wsel <= ~wsel;
		wx <= 10'd0;
		half <= 1'b1;
		l_sel <= wsel;
		l_act_x <= act_x_w;
		l_first <= vb_line && !vb_prev;
		line_tgl <= ~line_tgl;
		vb_prev <= vb_line;
		vb_line <= 1'b0;
	end else begin
		if (half && wx != 10'h3FF) wx <= wx + 10'd1;
		if (vblank_n) vb_line <= 1'b1;
		if (hblank_n && !hb_d) act_x_w <= wx;
	end
end

wire [15:0] wdata = {hblank_n & vblank_n, r_in[7:3], g_in[7:3], b_in[7:3]};
wire [15:0] rdata;
reg rsel = 1'b0;
reg [9:0] rx = 10'd0;

kg_sdpram #(.DW(16), .AW(11)) line_buf(
	.clka(clk_sys), .wea(half), .addra({wsel, wx}), .dina(wdata),
	.clkb(clk_pix), .enb(1'b1), .addrb({rsel, rx}), .doutb(rdata)
);

// ---- clk_pix: the output timing
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] tgl_s = 3'b000;
wire line_ev = tgl_s[2] != tgl_s[1];

reg [9:0] hx = 10'd0;          // clk since the start of the output line
reg second = 1'b0;             // line B of the SNES line
reg [9:0] oy = 10'd0;          // output line of the frame, 0 = the first line of VS
reg [9:0] lc = 10'd0;          // output lines since the first active line
reg [9:0] frame_len = 10'd524;
reg [9:0] act_x = 10'd100;

wire [9:0] next_oy = (oy == frame_len - 10'd1) ? 10'd0 : oy + 10'd1;

always @(posedge clk_pix) begin
	tgl_s <= {tgl_s[1:0], line_tgl};

	if (line_ev) begin
		// line A of the SNES line written last
		rsel <= l_sel;
		act_x <= l_act_x;
		hx <= 10'd0;
		second <= 1'b0;
		if (l_first) begin
			// the first active line is output line 51: the window (35..514) starts 16 lines before it
			frame_len <= lc + 10'd1;
			lc <= 10'd0;
			oy <= 10'd51;
		end else begin
			lc <= lc + 10'd1;
			oy <= next_oy;
		end
	end else if (hx == 10'd799 && !second) begin
		hx <= 10'd0;
		second <= 1'b1;
		lc <= lc + 10'd1;
		oy <= next_oy;
	end else if (hx != 10'h3FF)
		hx <= hx + 10'd1;

	// the sample of the pixel: window x 64 (hx 208) = the first active sample
	rx <= act_x + hx - 10'd208;
end

wire h_win = hx >= 10'd144 && hx < 10'd784;
wire v_win = oy >= 10'd35 && oy < 10'd515;
wire h_sync = hx < 10'd96;
wire v_sync = oy < 10'd2;

// the buffer output is one clk after rx, which is one clk after hx
reg win_d1 = 1'b0, win_d2 = 1'b0, hs_d1 = 1'b0, hs_d2 = 1'b0, vs_d1 = 1'b0, vs_d2 = 1'b0;
always @(posedge clk_pix) begin
	{win_d2, win_d1} <= {win_d1, h_win && v_win};
	{hs_d2, hs_d1} <= {hs_d1, h_sync};
	{vs_d2, vs_d1} <= {vs_d1, v_sync};
	de <= win_d2;
	hs <= hs_d2;
	vs <= vs_d2;
	if (win_d2 && rdata[15]) begin
		r <= {rdata[14:10], rdata[14:12]};
		g <= {rdata[9:5], rdata[9:7]};
		b <= {rdata[4:0], rdata[4:2]};
	end else begin
		r <= 8'd0;
		g <= 8'd0;
		b <= 8'd0;
	end
end

endmodule
