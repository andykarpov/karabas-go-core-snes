`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_video.v

 The 15 kHz picture of main as 640 x 480 at 60 Hz with the timing of VESA / CEA 640 x 480 (HS 96,
 back porch 48, 640 active, front porch 16 = 800 clk; VS 2 lines, back porch 33, 480 active,
 front porch 10 = 525 lines), on its own pixel clock clk_pix = clk_sys x 40 / 34 (25.21 MHz, a
 second PLL of the top).

 The output timing runs free: its lines and syncs do not depend on main, so the monitor (and the
 OSD) keep a picture while the SNES is in reset (at power up until the MCU is ready, during a ROM
 load: the PPU stops its counters and HSYNC in reset). The first versions made each output line
 from a SNES line: no SNES lines, no syncs ("no signal"), and lines of 797 / 798 clk.

 Each line of the SNES (1364 clk_sys, 1360 the short one) is written into a ring of 4 line
 buffers, one sample per 2 clk_sys (682 samples: a dot of 256 is two samples, of 512 one), and is
 read out as two output lines, one sample per output pixel; a picture of 512 x 448 (478) in the
 middle of 640 x 480, the first active sample of the line at x 64 of the window, black outside.

 Frame lock: the first active line of a SNES frame (crossed as a toggle) is expected at output
 line 49 clk 0 (its two output lines are 51 and 52, a SNES line later, so the line is written whole
 before the read and is not overwritten while read). The frames of the SNES have two lengths
 that alternate: NTSC 262 lines with a short line every other frame, interlace fields of 263 and
 262 lines (PAL 313 / 312), so the output frame after an event is made as long as the SNES frame
 before the last one, P (event to event, clk_pix), plus the distance d of the event from line 49
 clk 0: c = d + P - 420000 (PAL 500000) clk are added, spread over the 512 lines from line 51
 (line 51 + i is 800 + floor((c + i) / 512) clk: they sum to c; the last ones are lines 0..37 of
 the next frame), and the next event comes at line 49 again. In the lock c is about +433 (NTSC,
 PAL +668; interlace +433 / +2038, PAL +668 / +2272), so these lines are 800 / 801 (up to 805),
 lines 38..50 always 800. The first versions added d alone (the length of the last frame):
 interlace fields came a SNES line off in turn, out of the window, and the output jumped to line
 49 every other frame (a monitor lost the picture). An event further than 3 lines
 from line 49 (the first frame, after a reset) sets the output to line 49 at once (one bad frame);
 without a P of the last frame (c out of range) c = d.
 A SNES frame of more than 287 lines (PAL) makes 625 output lines (50 Hz). No event during a frame:
 no lock, the picture is black.

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

// ---- clk_sys: the line buffers
reg hs_d = 1'b0, hb_d = 1'b0;
reg [1:0] wsel = 2'd0;         // the line being written
reg half = 1'b0;               // the sample phase (a sample per 2 clk)
reg [9:0] wx = 10'd0;
reg [9:0] act_x_w = 10'd100;   // the first active sample of the line being written
reg vb_line = 1'b0, vb_prev = 1'b0;
reg [9:0] lines = 10'd0;       // SNES lines since the first active line

// of the first active line of the last frame, held during the frame
reg frame_tgl = 1'b0;
reg [1:0] f_sel = 2'd0;
reg [9:0] f_act_x = 10'd100;
reg f_pal = 1'b0;

wire new_line = hsync_in && !hs_d;

always @(posedge clk_sys) begin
	hs_d <= hsync_in;
	hb_d <= hblank_n;
	half <= ~half;
	if (new_line) begin
		wsel <= wsel + 2'd1;
		wx <= 10'd0;
		half <= 1'b1;
		if (lines != 10'h3FF) lines <= lines + 10'd1;
		if (vb_line && !vb_prev) begin
			// the line written last is the first active line
			f_sel <= wsel;
			f_act_x <= act_x_w;
			f_pal <= lines > 10'd287;
			frame_tgl <= ~frame_tgl;
			lines <= 10'd0;
		end
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
reg [1:0] rsel = 2'd0;
reg [9:0] rx = 10'd0;

kg_sdpram #(.DW(16), .AW(12)) line_buf(
	.clka(clk_sys), .wea(half), .addra({wsel, wx}), .dina(wdata),
	.clkb(clk_pix), .enb(1'b1), .addrb({rsel, rx}), .doutb(rdata)
);

// ---- clk_pix: the output timing
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] tgl_s = 3'b000;
wire frame_ev = tgl_s[2] != tgl_s[1];

reg [9:0] hx = 10'd0;          // clk since the start of the output line
reg [9:0] hlast = 10'd799;     // the last clk of the line
reg [9:0] oy = 10'd0;          // output line of the frame, 0 = the first line of VS
reg second = 1'b0;             // the second output line of a SNES line
reg [1:0] p_sel = 2'd0;        // the buffer of the first active line
reg [9:0] act_x = 10'd100;
reg pal = 1'b0;
reg signed [12:0] c_cur = 13'sd0;
reg ev = 1'b0, locked = 1'b0;
reg [19:0] p_cnt = 20'hFFFFF;  // clk since the last event (saturates)
reg [19:0] p_last = 20'hFFFFF; // the SNES frame before: event to event
reg c_on = 1'b0;               // the lines of the correction
reg [8:0] ci = 9'd0;

wire [9:0] oy_n = (oy == (pal ? 10'd624 : 10'd524)) ? 10'd0 : oy + 10'd1;
wire ci_start = oy_n == 10'd51;
wire [8:0] ci_n = ci_start ? 9'd0 : ci + 9'd1;
wire on_n = ci_start || (c_on && ci != 9'd511);
wire signed [13:0] corr_sum = $signed({c_cur[12], c_cur}) + $signed({5'd0, ci_n});
wire signed [13:0] corr = corr_sum >>> 9;
wire near = oy >= 10'd46 && oy <= 10'd52;
reg signed [12:0] d_line;
always @* begin
	case (oy[3:0])
	4'd14: d_line = -13'sd2400;    // 46
	4'd15: d_line = -13'sd1600;
	4'd0:  d_line = -13'sd800;
	4'd2:  d_line = 13'sd800;
	4'd3:  d_line = 13'sd1600;
	4'd4:  d_line = 13'sd2400;     // 52
	default: d_line = 13'sd0;      // 49
	endcase
end
wire signed [12:0] d_meas = near ? $signed({3'b000, hx}) + d_line : 13'sd0;
// c = d + P - the output frame; out of range (no P): d
wire signed [21:0] c_full = $signed({{9{d_meas[12]}}, d_meas}) + $signed({2'b00, p_last})
	- (f_pal ? 22'sd500000 : 22'sd420000);
wire c_ok = c_full >= -22'sd4096 && c_full <= 22'sd4095;

always @(posedge clk_pix) begin
	tgl_s <= {tgl_s[1:0], frame_tgl};

	if (p_cnt != 20'hFFFFF) p_cnt <= p_cnt + 20'd1;

	if (frame_ev && !near) begin
		// out of lock: start line 49 now
		hx <= 10'd0;
		hlast <= 10'd799;
		oy <= 10'd49;
		c_on <= 1'b0;
	end else if (hx == hlast) begin
		hx <= 10'd0;
		oy <= oy_n;
		c_on <= on_n;
		ci <= ci_n;
		hlast <= on_n ? 10'd799 + corr[9:0] : 10'd799;
		if (oy_n == 10'd0) begin
			if (!ev) c_cur <= 13'sd0;
			ev <= 1'b0;
			locked <= ev;
		end
		if (oy_n == 10'd51) begin
			rsel <= p_sel;
			second <= 1'b0;
		end else begin
			second <= ~second;
			if (second) rsel <= rsel + 2'd1;
		end
	end else
		hx <= hx + 10'd1;

	if (frame_ev) begin
		c_cur <= c_ok ? c_full[12:0] : d_meas;
		p_cnt <= 20'd1;
		p_last <= p_cnt;
		ev <= 1'b1;
		p_sel <= f_sel;
		act_x <= f_act_x;
		pal <= f_pal;
	end

	// the sample of the pixel: window x 64 (hx 208) = the first active sample
	rx <= act_x + hx - 10'd208;
end

wire h_win = hx >= 10'd144 && hx < 10'd784;
wire v_win = oy >= 10'd35 && oy < 10'd515;
wire pic = locked && oy >= 10'd51;
wire h_sync = hx < 10'd96;
wire v_sync = oy < 10'd2;

// the buffer output is one clk after rx, which is one clk after hx
reg win_d1 = 1'b0, win_d2 = 1'b0, pic_d1 = 1'b0, pic_d2 = 1'b0;
reg hs_d1 = 1'b0, hs_d2 = 1'b0, vs_d1 = 1'b0, vs_d2 = 1'b0;
always @(posedge clk_pix) begin
	{win_d2, win_d1} <= {win_d1, h_win && v_win};
	{pic_d2, pic_d1} <= {pic_d1, pic};
	{hs_d2, hs_d1} <= {hs_d1, h_sync};
	{vs_d2, vs_d1} <= {vs_d1, v_sync};
	de <= win_d2;
	hs <= hs_d2;
	vs <= vs_d2;
	if (win_d2 && pic_d2 && rdata[15]) begin
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
