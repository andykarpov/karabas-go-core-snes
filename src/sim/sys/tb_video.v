`timescale 1ns / 1ps

// snes_video with clk_sys 21.429 MHz and clk_pix = clk_sys x 40 / 34 (the PLLs of the tops, no
// common phase assumed), main modelled by its timing: lines of 1364 clk (NTSC: every other frame
// one line of 1360), 262 lines (PAL 312), HSYNC at the start of a line, 256 active dots (1024 clk)
// from clk 288 of lines 1..224 (HBLANKn / VBLANKn), the pixel colour = a pattern of x and y.
// Interlace as PPU.vhd makes it: the fields of 263 and 262 lines (PAL 313 and 312, the second
// with a dot more on its last line), no short line; overscan: 239 active lines.
// main runs NTSC, stops (the reset of the SNES: no HSYNC), runs again, then PAL, NTSC interlace,
// PAL interlace, NTSC overscan. Checked on the output in each phase after the frames to lock:
// lines of 800 clk, those of the lock (all but lines 38..50) 800..810, HS 96, DE 640 clk starting
// 144 after HS, 480 DE lines per frame starting 35 lines after VS (2 lines), 525 lines per frame
// (PAL 625); while main runs the picture: the first active pixel at window x 64 and line 16,
// 512 x 448 (overscan: to the end of the window, 464 lines), black around it; while it stops a
// black picture and the same timing; while it runs the picture keeps its phase to the SNES frame
// (the lock; interlace: the fields of two lengths). A watchdog for a stopped output (no VS for
// 40 ms: a frame of up to 35 ms when PAL goes to NTSC, the output set to line 49 near the end of
// a PAL frame).

module tb_video;

parameter real T_SYS = 46.667;
parameter real T_PIX = 46.667 * 34.0 / 40.0;

reg clk_sys = 1'b0, clk_pix = 1'b0;
always #(T_SYS / 2.0) clk_sys = ~clk_sys;
initial begin #3.1; forever #(T_PIX / 2.0) clk_pix = ~clk_pix; end

// ---- main
integer hc = 0, vc = 0, frame = 0;
real t_snes = 0.0;             // the start of the first active line
reg run = 1'b1, pal_mode = 1'b0, ilace = 1'b0, ovscan = 1'b0, field = 1'b0;
reg hsync = 1'b0, hblank_n = 1'b0, vblank_n = 1'b0;
reg [7:0] r = 0, g = 0, b = 0;
always @(posedge clk_sys) begin
	if (!run) begin
		hc = 0; vc = 0;
		hsync <= 1'b0; vblank_n <= 1'b0; hblank_n <= 1'b0;
	end else begin
		hc = hc + 1;
		if (hc == ((vc == 100 && frame[0] && !pal_mode && !ilace) ? 1360 :
		           (vc == 311 && field && pal_mode && ilace) ? 1368 : 1364)) begin
			hc = 0;
			vc = vc + 1;
			if (vc >= (pal_mode ? 312 : 262) + (ilace && !field)) begin
				vc = 0; frame = frame + 1; field = ~field;
			end
		end
		hsync <= hc < 100;
		if (hc == 0 && vc == 1) t_snes = $realtime;
		vblank_n <= vc >= 1 && vc <= (ovscan ? 239 : 224);
		hblank_n <= hc >= 288 && hc < 288 + 1024;
	end
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
integer first_de_line = -1, vs_lines = 0, frames = 0, pic_px = 0, pic_line = 0, pic_lines = 0;
integer checked = 0, bp_min = 800, bp_max = 800;
reg hs_d = 0, vs_d = 0, de_d = 0, check = 0, want_pic = 0;
integer x_first = -1, n_lines = 525, n_pic = 448;
real phase = 0.0, phase_d = 0.0, t_line = 0.0;
reg phase_ok = 0;

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
		// a new line: line_len is the length of output line (line)
		if (check) begin
			if (line < 38 || line > 50) begin
				if (line_len < 800 || line_len > 810) fail("lock line length", line_len);
				if (line_len < bp_min) bp_min = line_len;
				if (line_len > bp_max) bp_max = line_len;
			end else if (line_len != 800) fail("line length", line_len);
			if (de_len != 0 && de_len != 640) fail("DE length", de_len);
			if (de_len != 0 && de_start != 144) fail("DE start", de_start);
			if (want_pic && pic_px != 0 && pic_px != 512) fail("picture width", pic_px);
			if (want_pic && pic_px != 0 && x_first != 64) fail("picture x", x_first);
			if (!want_pic && pic_px != 0) fail("picture while stopped", pic_px);
		end
		if (de_len) begin
			if (first_de_line < 0) first_de_line = line;
			de_lines = de_lines + 1;
		end
		if (pic_px) begin
			pic_lines = pic_lines + 1;
			if (pic_lines == 1) pic_line = line - first_de_line;
		end
		if (pic_px && pic_lines == 1) begin
			// the lock: the picture keeps its phase to the SNES frame (the short line of every
			// other NTSC frame: 4 clk_sys); t_snes: the first active line of this SNES frame
			phase = t_line - t_snes;
			if (check && want_pic && phase_ok && (phase - phase_d > 6.0 * T_PIX || phase_d - phase > 6.0 * T_PIX))
				fail("picture phase moved by clk", (phase - phase_d) / T_PIX);
			phase_d = phase;
			phase_ok = check;
		end
		t_line = $realtime;
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
			checked = checked + 1;
			if (line != n_lines) fail("lines per frame", line);
			if (de_lines != 480) fail("DE lines", de_lines);
			if (first_de_line != 35) fail("first DE line", first_de_line);
			if (want_pic && pic_lines != n_pic) fail("picture lines", pic_lines);
			if (want_pic && pic_line != 16) fail("picture line", pic_line);
		end
		frames = frames + 1;
		// the phases, in output frames: NTSC 4..8 checked, stopped 9..13 (checked 10..13), NTSC
		// again 14..21 (checked 17..21), PAL 22..31 (checked 25..31), NTSC interlace 32..41
		// (checked 35..41), PAL interlace 42..51 (checked 45..51), NTSC overscan 52..59
		// (checked 55..59)
		case (frames)
		4: begin check = 1; want_pic = 1; end
		9: begin check = 0; run <= 0; phase_ok = 0; end
		10: begin check = 1; want_pic = 0; end
		14: begin check = 0; run <= 1; end
		17: begin check = 1; want_pic = 1; end
		22: begin check = 0; pal_mode <= 1; phase_ok = 0; end
		25: begin check = 1; n_lines = 625; end
		32: begin check = 0; pal_mode <= 0; ilace <= 1; phase_ok = 0; end
		35: begin check = 1; n_lines = 525; end
		42: begin check = 0; pal_mode <= 1; phase_ok = 0; end
		45: begin check = 1; n_lines = 625; end
		52: begin check = 0; pal_mode <= 0; ilace <= 0; ovscan <= 1; phase_ok = 0; end
		55: begin check = 1; n_lines = 525; n_pic = 464; end
		default: ;
		endcase
		line = 0; de_lines = 0; first_de_line = -1; pic_lines = 0; pic_line = 0;
	end
	if (vs_d && !vs && check && vs_lines != 2) fail("VS lines", vs_lines);
	if (!vs) vs_lines = 0;
end

// a watchdog: a frame (VS) at least every 40 ms
integer last_frame = 0;
always @(frames) last_frame = $time / 1000000;
always #1000000 if ($time / 1000000 - last_frame > 40) begin
	fail("no VS for ms", $time / 1000000 - last_frame);
	$display("tb_video: %0d errors", errors);
	$finish;
end

initial begin
	wait (frames == 60);
	$display("tb_video: %0d frames checked, lock lines %0d..%0d clk", checked, bp_min, bp_max);
	if (checked != 40) fail("frames checked", checked);
	$display("tb_video: %0d errors", errors);
	$finish;
end

endmodule
