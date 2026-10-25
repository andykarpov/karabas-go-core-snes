`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_video.v

 The 15 kHz picture of main to 31 kHz, with no other clock than clk_sys (the SNES master clock):
 a line of the SNES is 1364 clk_sys (1360 the short line), it is written into a line buffer one
 sample per 2 clk_sys (682 samples, a dot of 256 is two samples, of 512 one) and read out twice
 at one sample per clk_sys during the next line: 682 clk_sys per line, 31.5 kHz, 524 lines,
 60.1 Hz (PAL: 624 lines, 50 Hz). The pixel clock of the output is clk_sys.

 Output window (DE): 640 x 480 around the picture of the SNES (512 x 448 / 478), black outside
 it; the 42 clk of horizontal blanking hold the sync (HS 32 clk, 2 clk after DE). The window is
 placed by the blanking of main: it starts 64 samples before the first active sample of the
 line and 16 lines (of 31 kHz) before the first active line of the frame. A window that runs
 past the end of an output line goes on into the next one: the samples there are blanking. VS (2 lines) is 10
 lines after the end of the window. hs / vs are active high, as kg_osd_overlay counts them.

 Buffer: kg_sdpram 2 x 1024 x 16 (two lines: {active, R5, G5, B5}).
*/

module snes_video (
	input wire clk,

	input wire [7:0] r_in,
	input wire [7:0] g_in,
	input wire [7:0] b_in,
	input wire hsync_in,       // active high, from main
	input wire vsync_in,       // not used: the frame is found by vblank_n
	input wire hblank_n,
	input wire vblank_n,

	output reg [7:0] r = 8'd0,
	output reg [7:0] g = 8'd0,
	output reg [7:0] b = 8'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0
);

// ---- input side
reg hs_d = 1'b0, hb_d = 1'b0, vb_line = 1'b0, vb_prev = 1'b0;
reg wsel = 1'b0;               // the line being written
reg half = 1'b0;               // the sample phase (a sample per 2 clk)
reg [9:0] wx = 10'd0;
reg [9:0] act_x = 10'd100;     // the first active sample of the last line
reg first_act = 1'b0;          // the last input line was the first active line of a frame
wire new_line = hsync_in && !hs_d;

always @(posedge clk) begin
	hs_d <= hsync_in;
	hb_d <= hblank_n;
	half <= ~half;
	if (new_line) begin
		wsel <= ~wsel;
		wx <= 10'd0;
		half <= 1'b1;
		first_act <= vb_line && !vb_prev;
		vb_prev <= vb_line;
		vb_line <= 1'b0;
	end else begin
		if (half && wx != 10'h3FF) wx <= wx + 10'd1;
		if (vblank_n) vb_line <= 1'b1;
		if (hblank_n && !hb_d) act_x <= wx;
	end
end

wire [15:0] wdata = {hblank_n & vblank_n, r_in[7:3], g_in[7:3], b_in[7:3]};
wire [15:0] rdata;
reg [9:0] ox = 10'd0;          // the sample being read
reg osel = 1'b0;

kg_sdpram #(.DW(16), .AW(11)) line_buf(
	.clka(clk), .wea(half), .addra({wsel, wx}), .dina(wdata),
	.clkb(clk), .enb(1'b1), .addrb({osel, ox}), .doutb(rdata)
);

// ---- output side: the samples of an input line twice, one per clk
reg [9:0] olen = 10'd682;
reg second = 1'b0;
reg [9:0] dx = 10'd0;          // clk since the start of the window of this line
reg dx_run = 1'b0;
reg [9:0] dy = 10'd0;          // output lines since the first active line
reg [9:0] frame_len = 10'd524;
wire [9:0] de_x0 = (act_x > 10'd64) ? act_x - 10'd64 : 10'd0;
reg line_start = 1'b0;

always @(posedge clk) begin
	line_start <= 1'b0;
	if (new_line) begin
		// the line written last is read now
		osel <= wsel;
		olen <= wx;
		ox <= 10'd0;
		second <= 1'b0;
		line_start <= 1'b1;
	end else if (ox == olen - 10'd1 && !second) begin
		ox <= 10'd0;
		second <= 1'b1;
		line_start <= 1'b1;
	end else if (ox != 10'h3FF)
		ox <= ox + 10'd1;

	if (line_start) begin
		if (first_act && !second) begin
			frame_len <= dy + 10'd1;
			dy <= 10'd0;
		end else if (dy != 10'h3FF)
			dy <= dy + 10'd1;
	end

	// the window: 640 clk from de_x0; HS 2 clk after it for 32 clk
	if (ox == de_x0) begin
		dx <= 10'd0;
		dx_run <= 1'b1;
	end else if (dx_run && dx != 10'h3FF)
		dx <= dx + 10'd1;
end

// lines of the window: 16 before the first active line to 464 after it
wire v_win = (dy >= frame_len - 10'd16) || (dy < 10'd464);
wire h_win = dx_run && dx < 10'd640;
wire h_sync = dx_run && dx >= 10'd642 && dx < 10'd674;
wire v_sync = dy >= 10'd474 && dy < 10'd476;

// the buffer output is one clk late: the window and syncs of this clk go with the next pixel
reg win_d = 1'b0, hsync_d = 1'b0, vsync_d = 1'b0;
always @(posedge clk) begin
	win_d <= h_win && v_win;
	hsync_d <= h_sync;
	vsync_d <= v_sync;
	de <= win_d;
	hs <= hsync_d;
	vs <= vsync_d;
	if (win_d && rdata[15]) begin
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
