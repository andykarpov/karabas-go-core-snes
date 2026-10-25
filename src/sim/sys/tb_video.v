`timescale 1ns / 1ps

// snes_video with clk_sys 21.429 MHz and clk_pix = clk_sys x 41 / 35 (the PLLs of the tops, no
// common phase assumed), main modelled by its timing: lines of 1364 clk (every other frame one
// line of 1360), 262 lines, HSYNC at the start of a line, 256 active dots (1024 clk) from clk 288
// of lines 1..224 (HBLANKn / VBLANKn), the pixel colour = a pattern of x and y. Checked on the
// output, after two frames to settle: lines of 797..800 clk_pix, HS 96, DE 640 clk starting 144
// after HS, 480 DE lines per frame starting 35 lines after VS (2 lines), 524 lines per frame, the
// picture: the first active pixel at window x 64 and line 16, 512 x 448, black around it.

module tb_video;

parameter real T_SYS = 46.667;
parameter real T_PIX = 46.667 * 35.0 / 41.0;

reg clk_sys = 1'b0, clk_pix = 1'b0;
always #(T_SYS / 2.0) clk_sys = ~clk_sys;
initial begin #3.1; forever #(T_PIX / 2.0) clk_pix = ~clk_pix; end

// ---- main
integer hc = 0, vc = 0, frame = 0;
reg hsync = 1'b0, hblank_n = 1'b0, vblank_n = 1'b0;
reg [7:0] r = 0, g = 0, b = 0;
always @(posedge clk_sys) begin
	hc = hc + 1;
	if (hc == ((vc == 100 && frame[0]) ? 1360 : 1364)) begin
		hc = 0;
		vc = vc + 1;
		if (vc == 262) begin vc = 0; frame = frame + 1; end
	end
	hsync <= hc < 100;
	vblank_n <= vc >= 1 && vc <= 224;
	hblank_n <= hc >= 288 && hc < 288 + 1024;
	// dot x (0..255) of 4 clk, line y: r = x, g = y, b = 0x5A
	r <= (hc - 288) >> 2;
	g <= vc - 1;
	b <= 8'h5A;
end

wire [7:0] vr, vg, vb;
wire hs, vs, de;
snes_video dut(
	.clk_sys(clk_sys), .clk_pix(clk_pix),
	.r_in(r), .g_in(g), .b_in(b), .hsync_in(hsync), .hblank_n(hblank_n), .vblank_n(vblank_n),
	.r(vr), .g(vg), .b(vb), .hs(hs), .vs(vs), .de(de)
);

// ---- checks
integer errors = 0;
task fail;
	input [8*48-1:0] msg;
	input integer v;
	begin
		errors = errors + 1;
		if (errors < 20) $display("%t: %0s %0d", $time, msg, v);
	end
endtask

integer px = 0, hs_len = 0, line_len = 0, de_len = 0, de_start = 0, line = 0, de_lines = 0;
integer first_de_line = -1, vs_lines = 0, frame_lines = 0, frames = 0, pic_px = 0, pic_line = 0;
reg hs_d = 0, vs_d = 0, de_d = 0, check = 0;
integer x_first = -1;

always @(posedge clk_pix) begin
	hs_d <= hs; vs_d <= vs; de_d <= de;
	px = px + 1;
	if (hs) hs_len = hs_len + 1;
	if (de) begin
		if (!de_d) de_start = px;
		de_len = de_len + 1;
		// the picture: lines 16..463 of the window, x 64..575
		if (vr != 0 || vg != 0 || vb != 0) begin
			pic_px = pic_px + 1;
			if (x_first < 0) x_first = de_len - 1;
			if (check && vb != 8'h5A) fail("blue", vb);
		end
	end
	if (hs && !hs_d) begin
		// a new line
		if (check) begin
			if (line_len < 793 || line_len > 800) fail("line length", line_len);
			if (de_len != 0 && de_len != 640) fail("DE length", de_len);
			if (de_len != 0 && de_start != 144) fail("DE start", de_start);
			if (pic_px != 0 && pic_px != 512) fail("picture width", pic_px);
			if (pic_px != 0 && x_first != 64) fail("picture x", x_first);
		end
		if (de_len) begin
			if (first_de_line < 0) first_de_line = line;
			de_lines = de_lines + 1;
		end
		if (pic_px) pic_line = pic_line + 1;
		if (de_len && pic_px && pic_line == 1 && check && line - first_de_line != 16) fail("picture line", line - first_de_line);
		line_len = 0; hs_len = 1; de_len = 0; pic_px = 0; x_first = -1; // hs is high in this clk
		px = 0;
		line = line + 1;
		if (vs) vs_lines = vs_lines + 1;
	end
	line_len = line_len + 1;
	if (hs_d && !hs && check && hs_len != 96) fail("HS length", hs_len);
	if (vs && !vs_d) begin
		// a new frame
		if (check) begin
			if (line != 524) fail("lines per frame", line);
			if (de_lines != 480) fail("DE lines", de_lines);
			if (first_de_line != 35) fail("first DE line", first_de_line);
			if (pic_line != 448) fail("picture lines", pic_line);
		end
		if (frames >= 2) check = 1;
		frames = frames + 1;
		line = 0; de_lines = 0; first_de_line = -1; pic_line = 0;
	end
	if (vs_d && !vs && check && vs_lines != 2) fail("VS lines", vs_lines);
	if (!vs) vs_lines = 0;
end

initial begin
	wait (frames == 6);
	$display("tb_video: %0d frames checked", frames - 3);
	$display("tb_video: %0d errors", errors);
	$finish;
end

endmodule
