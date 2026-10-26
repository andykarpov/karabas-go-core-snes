`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_video.v

 The 15 kHz picture of main in a standard mode of 31 kHz, on the pixel clock clk_pix of the top:
 - NTSC: 640 x 480 at 60 Hz, the timing of VESA / CEA 640 x 480 (HS 96, back porch 48, 640
   active, front porch 16 = 800 clk; VS 2 lines, back porch 33, 480 active, front porch 10 = 525
   lines), clk_pix = clk_sys x 40 / 34 = 25.21 MHz;
 - PAL: 720 x 576 at 50 Hz, the timing of CEA 576p (HS 64, back porch 68, 720 active, front porch
   12 = 864 clk; VS 5 lines, back porch 39, 576 active, front porch 5 = 625 lines), clk_pix =
   clk_sys x 28 / 22 = 27.27 MHz. The first versions made PAL as 800 x 625 lines (480 of DE) at
   50 Hz, no standard mode: a monitor showed no picture (a game of Europe, R-Type).
 The mode follows pal (the region of the SNES, clk_sys): a change starts a new output frame at
 once, as the top switches clk_pix with it.

 The output timing runs free: its lines and syncs do not depend on main, so the monitor (and the
 OSD) keep a picture while the SNES is in reset (at power up until the MCU is ready, during a ROM
 load: the PPU stops its counters and HSYNC in reset). The first versions made each output line
 from a SNES line: no SNES lines, no syncs ("no signal"), and lines of 797 / 798 clk.

 Each line of the SNES (1364 clk_sys, 1360 the short one) is written into a ring of 4 line
 buffers, one sample per 2 clk_sys (682 samples: a dot of 256 is two samples, of 512 one), and is
 read out as two output lines, one sample per output pixel; a picture of 512 x 448 (478), the
 first active sample of the line at x 64 of the window (PAL 104: the middle of 720), the first
 line at line 16 of the window (PAL 64: 448 in the middle of 576, 478 of overscan fit), black
 outside. NTSC overscan (239 lines) loses its last 14 output lines.

 Frame lock: the first active line of a SNES frame (crossed as a toggle) is expected at output
 line 49 clk 0 (PAL 106; its two output lines are 51 and 52 (108, 109), a SNES line later, so the
 line is written whole before the read and is not overwritten while read). The frames of the SNES have two lengths
 that alternate: NTSC 262 lines with a short line every other frame, interlace fields of 263 and
 262 lines (PAL 313 / 312), so the output frame after an event is made as long as the SNES frame
 before the last one, P (event to event, clk_pix), plus the distance d of the event from line 49
 clk 0: c = d + P - 420000 (PAL 540000) clk are added, spread over the 512 lines from line 51
 (line 51 + i is 800 + floor((c + i) / 512) clk: they sum to c; the last ones are lines 0..37 of
 the next frame; PAL lines 108..619 of 864 clk), and the next event comes at line 49 again. In the
 lock c is about +433 (NTSC; interlace +433 / +2038; PAL +1632, interlace +1632 / +3373), so these
 lines are 800 / 801 (up to 805; PAL 867 / 868, up to 871), the lines around the event always
 800 (864). The first versions added d alone (the length of the last frame):
 interlace fields came a SNES line off in turn, out of the window, and the output jumped to line
 49 every other frame (a monitor lost the picture). An event further than 3 lines
 from line 49 (the first frame, after a reset) sets the output to line 49 at once (one bad frame);
 without a P of the last frame (c out of range) c = d.
 No event during a frame: no lock, the picture is black.

 Outputs: rgb, hs, vs (active high), de, all registers of clk_pix in the same clk; osd_hs, osd_vs
 for the OSD overlay (its offsets count from their leading edges): hs and vs in NTSC, in PAL
 pulses later by 28 clk and 58 lines, so the OSD keeps its place to the picture.
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
	input wire pal,            // the mode: 0 640 x 480, 1 720 x 576

	output reg [7:0] r = 8'd0,
	output reg [7:0] g = 8'd0,
	output reg [7:0] b = 8'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0,
	output reg osd_hs = 1'b0,
	output reg osd_vs = 1'b0
);

// ---- clk_sys: the line buffers
reg hs_d = 1'b0, hb_d = 1'b0;
reg [1:0] wsel = 2'd0;         // the line being written
reg half = 1'b0;               // the sample phase (a sample per 2 clk)
reg [9:0] wx = 10'd0;
reg [9:0] act_x_w = 10'd100;   // the first active sample of the line being written
reg vb_line = 1'b0, vb_prev = 1'b0;

// of the first active line of the last frame, held during the frame
reg frame_tgl = 1'b0;
reg [1:0] f_sel = 2'd0;
reg [9:0] f_act_x = 10'd100;

wire new_line = hsync_in && !hs_d;

always @(posedge clk_sys) begin
	hs_d <= hsync_in;
	hb_d <= hblank_n;
	half <= ~half;
	if (new_line) begin
		wsel <= wsel + 2'd1;
		wx <= 10'd0;
		half <= 1'b1;
		if (vb_line && !vb_prev) begin
			// the line written last is the first active line
			f_sel <= wsel;
			f_act_x <= act_x_w;
			frame_tgl <= ~frame_tgl;
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
(* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] pal_s = 2'b00;
wire frame_ev = tgl_s[2] != tgl_s[1];

reg [9:0] hx = 10'd0;          // clk since the start of the output line
reg [9:0] hlast = 10'd799;     // the last clk of the line
reg [9:0] oy = 10'd0;          // output line of the frame, 0 = the first line of VS
reg second = 1'b0;             // the second output line of a SNES line
reg [1:0] p_sel = 2'd0;        // the buffer of the first active line
reg [9:0] act_x = 10'd100;
reg m_pal = 1'b0;              // the mode of this frame
reg signed [13:0] c_cur = 14'sd0;
reg ev = 1'b0, locked = 1'b0;
reg [19:0] p_cnt = 20'hFFFFF;  // clk since the last event (saturates)
reg [19:0] p_last = 20'hFFFFF; // the SNES frame before: event to event
reg c_on = 1'b0;               // the lines of the correction
reg [8:0] ci = 9'd0;

// the mode: NTSC 640 x 480 (800 x 525), PAL 720 x 576 (864 x 625)
wire [9:0] h_total = m_pal ? 10'd863 : 10'd799;   // the last clk of a line
wire [9:0] v_total = m_pal ? 10'd624 : 10'd524;   // the last line
wire [9:0] ev_line = m_pal ? 10'd106 : 10'd49;
wire [9:0] pic_line = m_pal ? 10'd108 : 10'd51;
wire [9:0] pic_x = m_pal ? 10'd236 : 10'd208;     // HS + back porch + 104 (64)
wire [19:0] f_len = m_pal ? 20'd540000 : 20'd420000;

wire [9:0] oy_n = (oy == v_total) ? 10'd0 : oy + 10'd1;
wire ci_start = oy_n == pic_line;
wire [8:0] ci_n = ci_start ? 9'd0 : ci + 9'd1;
wire on_n = ci_start || (c_on && ci != 9'd511);
wire signed [14:0] corr_sum = $signed({c_cur[13], c_cur}) + $signed({6'd0, ci_n});
wire signed [14:0] corr = corr_sum >>> 9;
wire [9:0] ev_rel = oy - ev_line;
wire near = oy >= ev_line - 10'd3 && oy <= ev_line + 10'd3;
reg signed [12:0] d_line;
always @* begin
	case (ev_rel[2:0])
	3'd5: d_line = m_pal ? -13'sd2592 : -13'sd2400;  // 3 lines before
	3'd6: d_line = m_pal ? -13'sd1728 : -13'sd1600;
	3'd7: d_line = m_pal ? -13'sd864 : -13'sd800;
	3'd1: d_line = m_pal ? 13'sd864 : 13'sd800;
	3'd2: d_line = m_pal ? 13'sd1728 : 13'sd1600;
	3'd3: d_line = m_pal ? 13'sd2592 : 13'sd2400;    // 3 lines after
	default: d_line = 13'sd0;
	endcase
end
wire signed [12:0] d_meas = near ? $signed({3'b000, hx}) + d_line : 13'sd0;
// c = d + P - the output frame; out of range (no P): d
wire signed [21:0] c_full = $signed({{9{d_meas[12]}}, d_meas}) + $signed({2'b00, p_last})
	- $signed({2'b00, f_len});
// up to 3 lines of d and a SNES frame of 3400 clk over: 14 bits (13 made c = d in PAL interlace)
wire c_ok = c_full >= -22'sd8192 && c_full <= 22'sd8191;

always @(posedge clk_pix) begin
	tgl_s <= {tgl_s[1:0], frame_tgl};
	pal_s <= {pal_s[0], pal};

	if (p_cnt != 20'hFFFFF) p_cnt <= p_cnt + 20'd1;

	if (m_pal != pal_s[1]) begin
		// a new mode (and clk_pix): a new frame now, the lock again
		m_pal <= pal_s[1];
		hx <= 10'd0;
		hlast <= pal_s[1] ? 10'd863 : 10'd799;
		oy <= 10'd0;
		c_on <= 1'b0;
		c_cur <= 14'sd0;
		ev <= 1'b0;
		locked <= 1'b0;
	end else if (frame_ev && !near) begin
		// out of lock: start the event line now
		hx <= 10'd0;
		hlast <= h_total;
		oy <= ev_line;
		c_on <= 1'b0;
	end else if (hx == hlast) begin
		hx <= 10'd0;
		oy <= oy_n;
		c_on <= on_n;
		ci <= ci_n;
		hlast <= on_n ? h_total + corr[9:0] : h_total;
		if (oy_n == 10'd0) begin
			if (!ev) c_cur <= 14'sd0;
			ev <= 1'b0;
			locked <= ev;
		end
		if (ci_start) begin
			rsel <= p_sel;
			second <= 1'b0;
		end else begin
			second <= ~second;
			if (second) rsel <= rsel + 2'd1;
		end
	end else
		hx <= hx + 10'd1;

	if (frame_ev) begin
		c_cur <= c_ok ? c_full[13:0] : {d_meas[12], d_meas};
		p_cnt <= 20'd1;
		p_last <= p_cnt;
		ev <= 1'b1;
		p_sel <= f_sel;
		act_x <= f_act_x;
	end

	// the sample of the pixel: pic_x = the first active sample
	rx <= act_x + hx - pic_x;
end

wire h_win = m_pal ? (hx >= 10'd132 && hx < 10'd852) : (hx >= 10'd144 && hx < 10'd784);
wire v_win = m_pal ? (oy >= 10'd44 && oy < 10'd620) : (oy >= 10'd35 && oy < 10'd515);
wire pic = locked && oy >= pic_line;
wire h_sync = hx < (m_pal ? 10'd64 : 10'd96);
wire v_sync = oy < (m_pal ? 10'd5 : 10'd2);
// the OSD: NTSC from the syncs; PAL in the same place to the picture: + 28 clk (236 - 208),
// + 58 lines (the OSD of 416 lines from line 124, in the middle of 576, less the 66 of NTSC)
wire o_hsync = m_pal ? (hx >= 10'd28 && hx < 10'd92) : h_sync;
wire o_vsync = m_pal ? (oy >= 10'd58 && oy < 10'd63) : v_sync;

// the buffer output is one clk after rx, which is one clk after hx
reg win_d1 = 1'b0, win_d2 = 1'b0, pic_d1 = 1'b0, pic_d2 = 1'b0;
reg hs_d1 = 1'b0, hs_d2 = 1'b0, vs_d1 = 1'b0, vs_d2 = 1'b0;
reg ohs_d1 = 1'b0, ohs_d2 = 1'b0, ovs_d1 = 1'b0, ovs_d2 = 1'b0;
always @(posedge clk_pix) begin
	{win_d2, win_d1} <= {win_d1, h_win && v_win};
	{pic_d2, pic_d1} <= {pic_d1, pic};
	{hs_d2, hs_d1} <= {hs_d1, h_sync};
	{vs_d2, vs_d1} <= {vs_d1, v_sync};
	{ohs_d2, ohs_d1} <= {ohs_d1, o_hsync};
	{ovs_d2, ovs_d1} <= {ovs_d1, o_vsync};
	de <= win_d2;
	hs <= hs_d2;
	vs <= vs_d2;
	osd_hs <= ohs_d2;
	osd_vs <= ovs_d2;
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
