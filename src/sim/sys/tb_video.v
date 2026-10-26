`timescale 1ns / 1ps

// snes_video with clk_sys 21.429 MHz and clk_pix = clk_sys x 40 / 34 (PAL x 28 / 22, switched with
// the mode as the tops do; the PLLs of the tops, no common phase assumed), main modelled by its timing: lines of 1364 clk (NTSC: every other frame
// one line of 1360), 262 lines (PAL 312), HSYNC at the start of a line, 256 active dots (1024 clk)
// from clk 288 of lines 1..224 (HBLANKn / VBLANKn), the pixel colour = a pattern of x and y.
// Interlace as PPU.vhd makes it: the fields of 263 and 262 lines (PAL 313 and 312, the second
// with a dot more on its last line), no short line; overscan: 239 active lines.
// main runs NTSC, stops (the reset of the SNES: no HSYNC), runs again, then PAL, NTSC interlace,
// PAL interlace, NTSC overscan, PAL overscan. Checked on the output in each phase after the frames
// to lock, NTSC (PAL): lines of 800 (864) clk, those of the lock (all but lines 38..50; PAL lines
// 108..619) up to 10 clk longer, HS 96 (64), DE 640 (720) clk starting 144 (132) after HS, 480
// (576) DE lines per frame starting 35 (44) lines after VS of 2 (5) lines, 525 (625) lines per
// frame; while main runs the picture: the first active pixel at window x 64 (104) and line 16
// (64), 512 x 448 (overscan: NTSC to the end of the window, 464 lines; PAL 478), black around it;
// while it stops a black picture and the same timing; while it runs the picture keeps its phase
// to the SNES frame (the lock; interlace: the fields of two lengths); the OSD syncs: NTSC with HS
// and VS, PAL 28 clk after HS and at line 58. A watchdog for a stopped output (no VS for
// 40 ms: a frame of up to 35 ms when PAL goes to NTSC, the output set to line 49 near the end of
// a PAL frame).

module tb_video;

parameter real T_SYS = 46.667;
parameter real T_NTSC = 46.667 * 34.0 / 40.0;
parameter real T_PAL = 46.667 * 22.0 / 28.0;

reg pal_mode = 1'b0;
real t_pix = T_NTSC;
always @(pal_mode) t_pix = pal_mode ? T_PAL : T_NTSC;
reg clk_sys = 1'b0, clk_pix = 1'b0;
always #(T_SYS / 2.0) clk_sys = ~clk_sys;
initial begin #3.1; forever #(t_pix / 2.0) clk_pix = ~clk_pix; end

// ---- main
integer hc = 0, vc = 0, frame = 0;
real t_snes = 0.0;             // the start of the first active line
reg run = 1'b1, ilace = 1'b0, ovscan = 1'b0, field = 1'b0;
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
wire hs, vs, de, osd_hs, osd_vs;
snes_video dut(
	.clk_sys(clk_sys), .clk_pix(clk_pix),
	.r_in(r), .g_in(g), .b_in(b), .hsync_in(hsync), .hblank_n(hblank_n), .vblank_n(vblank_n),
	.pal(pal_mode),
	.r(vr), .g(vg), .b(vb), .hs(hs), .vs(vs), .de(de), .osd_hs(osd_hs), .osd_vs(osd_vs)
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
integer checked = 0, bp_min = 800, bp_max = 800, bp_pal_min = 864, bp_pal_max = 864;
reg hs_d = 0, vs_d = 0, de_d = 0, ohs_d = 0, ovs_d = 0, check = 0, want_pic = 0;
// the expected mode (the phase): NTSC / PAL
reg e_pal = 0;
integer e_ht = 800, e_hs = 96, e_de = 640, e_des = 144, e_vde = 480, e_fde = 35, e_vs = 2;
integer e_px = 64, e_pl = 16;
always @(e_pal) begin
	e_ht = e_pal ? 864 : 800; e_hs = e_pal ? 64 : 96; e_de = e_pal ? 720 : 640;
	e_des = e_pal ? 132 : 144; e_vde = e_pal ? 576 : 480; e_fde = e_pal ? 44 : 35;
	e_vs = e_pal ? 5 : 2; e_px = e_pal ? 104 : 64; e_pl = e_pal ? 64 : 16;
end
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
			if (e_pal ? (line >= 108 && line <= 619) : (line < 38 || line > 50)) begin
				if (line_len < e_ht || line_len > e_ht + 10) fail("lock line length", line_len);
				if (!e_pal && line_len < bp_min) bp_min = line_len;
				if (!e_pal && line_len > bp_max) bp_max = line_len;
				if (e_pal && line_len < bp_pal_min) bp_pal_min = line_len;
				if (e_pal && line_len > bp_pal_max) bp_pal_max = line_len;
			end else if (line_len != e_ht) fail("line length", line_len);
			if (de_len != 0 && de_len != e_de) fail("DE length", de_len);
			if (de_len != 0 && de_start != e_des) fail("DE start", de_start);
			if (want_pic && pic_px != 0 && pic_px != 512) fail("picture width", pic_px);
			if (want_pic && pic_px != 0 && x_first != e_px) fail("picture x", x_first);
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
			if (check && want_pic && phase_ok && (phase - phase_d > 6.0 * t_pix || phase_d - phase > 6.0 * t_pix))
				fail("picture phase moved by clk", (phase - phase_d) / t_pix);
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
	if (hs_d && !hs && check && hs_len != e_hs) fail("HS length", hs_len);
	if (vs && !vs_d) begin
		// a new frame
		if (check) begin
			checked = checked + 1;
			if (line != n_lines) fail("lines per frame", line);
			if (de_lines != e_vde) fail("DE lines", de_lines);
			if (first_de_line != e_fde) fail("first DE line", first_de_line);
			if (want_pic && pic_lines != n_pic) fail("picture lines", pic_lines);
			if (want_pic && pic_line != e_pl) fail("picture line", pic_line);
		end
		frames = frames + 1;
		// the phases, in output frames: NTSC 4..8 checked, stopped 9..13 (checked 10..13), NTSC
		// again 14..21 (checked 17..21), PAL 22..31 (checked 25..31), NTSC interlace 32..41
		// (checked 35..41), PAL interlace 42..51 (checked 46..51:
		// a mode change and interlace, the lock takes a frame more), NTSC overscan 52..59
		// (checked 55..59), PAL overscan 60..67 (checked 63..67)
		case (frames)
		4: begin check = 1; want_pic = 1; end
		9: begin check = 0; run <= 0; phase_ok = 0; end
		10: begin check = 1; want_pic = 0; end
		14: begin check = 0; run <= 1; end
		17: begin check = 1; want_pic = 1; end
		22: begin check = 0; pal_mode <= 1; phase_ok = 0; end
		25: begin check = 1; n_lines = 625; e_pal = 1; end
		32: begin check = 0; pal_mode <= 0; ilace <= 1; phase_ok = 0; end
		35: begin check = 1; n_lines = 525; e_pal = 0; end
		42: begin check = 0; pal_mode <= 1; phase_ok = 0; end
		46: begin check = 1; n_lines = 625; e_pal = 1; end
		52: begin check = 0; pal_mode <= 0; ilace <= 0; ovscan <= 1; phase_ok = 0; end
		55: begin check = 1; n_lines = 525; n_pic = 464; e_pal = 0; end
		60: begin check = 0; pal_mode <= 1; phase_ok = 0; end
		63: begin check = 1; n_lines = 625; n_pic = 478; e_pal = 1; end
		default: ;
		endcase
		line = 0; de_lines = 0; first_de_line = -1; pic_lines = 0; pic_line = 0;
	end
	if (vs_d && !vs && check && vs_lines != e_vs) fail("VS lines", vs_lines);
	if (!vs) vs_lines = 0;
	// the OSD syncs: their leading edges to HS and VS
	ohs_d <= osd_hs; ovs_d <= osd_vs;
	if (osd_hs && !ohs_d && check && px != (e_pal ? 28 : 0)) fail("OSD HS at clk", px);
	if (osd_vs && !ovs_d && check && line != (e_pal ? 58 : 0)) fail("OSD VS at line", line);
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
	wait (frames == 68);
	$display("tb_video: %0d frames checked, lock lines %0d..%0d clk, PAL %0d..%0d", checked, bp_min,
		bp_max, bp_pal_min, bp_pal_max);
	if (checked != 44) fail("frames checked", checked);
	$display("tb_video: %0d errors", errors);
	$finish;
end

endmodule
