`timescale 1ns / 1ps

// snes_sram against a model of the two async SRAM chips (tAA 10 ns, with the delays of the
// board: T_OUT from the FPGA registers to the chips, T_IN back). The five ports are driven from
// clk_sys at the same time as the SNES side does (vram1 and vram2 often at the same address, a
// second toggle with a new address before the answer), every read is checked against a model
// of the memory, every answer must change at a ph 0 edge only. The chip model checks /WE (at
// least 8 ns low, the address stable from before /WE until after it) and that /OE and /WE are
// not low together.

module tb_sram;

parameter real T_OUT = 6.0;
parameter real T_IN = 4.0;
parameter integer N = 5000;

reg clk_mem = 1'b0;
reg clk_sys = 1'b0;
always #5.82 clk_mem = ~clk_mem;
initial begin
	#0.01;
	forever begin
		clk_sys = ~clk_sys;
		#23.28;
	end
end

wire [1:0] ph;
snes_phase phase(.clk_sys(clk_sys), .clk_mem(clk_mem), .ph(ph));

reg v1_req = 0, v2_req = 0, a_req = 0, b_req = 0, i_req = 0;
wire v1_ack, v2_ack, a_ack, b_ack, i_ack;
reg [14:0] v1_addr = 0, v2_addr = 0;
reg [7:0] v1_din = 0, v2_din = 0, a_din = 0, b_din = 0;
reg v1_we = 0, v2_we = 0, a_we = 0, b_we = 0, i_we = 0;
wire [7:0] v1_dout, v2_dout;
reg [15:0] a_addr = 0;
reg [19:0] b_addr = 0;
reg [21:0] i_addr = 0;
reg i_word = 0;
reg [15:0] i_din = 0;
wire [15:0] a_dout, b_dout, i_dout;

wire [20:0] ma;
wire [15:0] md;
wire [1:0] mwr_n, mrd_n;

snes_sram dut(
	.clk(clk_mem), .ph(ph),
	.vram1_req(v1_req), .vram1_ack(v1_ack), .vram1_addr(v1_addr), .vram1_din(v1_din), .vram1_we(v1_we), .vram1_dout(v1_dout),
	.vram2_req(v2_req), .vram2_ack(v2_ack), .vram2_addr(v2_addr), .vram2_din(v2_din), .vram2_we(v2_we), .vram2_dout(v2_dout),
	.aram_req(a_req), .aram_ack(a_ack), .aram_addr(a_addr), .aram_din(a_din), .aram_we(a_we), .aram_dout(a_dout),
	.bsram_req(b_req), .bsram_ack(b_ack), .bsram_addr(b_addr), .bsram_din(b_din), .bsram_we(b_we), .bsram_dout(b_dout),
	.io_req(i_req), .io_ack(i_ack), .io_addr(i_addr), .io_word(i_word), .io_din(i_din), .io_we(i_we), .io_dout(i_dout),
	.MA(ma), .MD(md), .MWR_N(mwr_n), .MRD_N(mrd_n)
);

// ---- the board and the chips (transport delays)
reg [20:0] c_a = 0;
reg [1:0] c_we_n = 2'b11, c_oe_n = 2'b11;
reg f_oe = 0;
reg [15:0] f_d = 0;
always @(ma or mwr_n or mrd_n or dut.md_oe or dut.md_out) begin
	c_a <= #(T_OUT) ma;
	c_we_n <= #(T_OUT) mwr_n;
	c_oe_n <= #(T_OUT) mrd_n;
	f_oe <= #(T_OUT) dut.md_oe;
	f_d <= #(T_OUT) dut.md_out;
end
wire [15:0] c_d = f_oe ? f_d : 16'bz;   // the data pins of the chips, from the FPGA

reg [15:0] sram_mem [0:(1<<21)-1];
integer errors = 0;
real t_a;
initial t_a = 0.0;
always @(c_a) begin
	t_a = $realtime;
	if (c_we_n != 2'b11) begin errors = errors + 1; $display("%t: address changes with /WE low", $time); end
end
genvar g;
generate for (g = 0; g < 2; g = g + 1) begin : chip
	real t_we_fall;
	initial t_we_fall = 0.0;
	always @(negedge c_we_n[g]) begin
		t_we_fall = $realtime;
		if (!c_oe_n[g]) begin errors = errors + 1; $display("%t: /WE and /OE low", $time); end
	end
	always @(posedge c_we_n[g]) begin
		if ($realtime > 0.0 && $realtime - t_we_fall < 8.0) begin errors = errors + 1; $display("%t: /WE pulse", $time); end
		if (t_a > t_we_fall) begin errors = errors + 1; $display("%t: address changed during /WE", $time); end
		sram_mem[c_a][g*8 +: 8] = c_d[g*8 +: 8];
	end
end endgenerate

// read data: valid tAA after the address (or tOE after /OE), X before; back T_IN later
reg [15:0] c_q = 16'hxxxx;
reg [15:0] q_b = 16'hxxxx;
reg [1:0] q_oe = 2'b00;   // per chip: /OE low and /WE high
always @(c_a or c_oe_n) begin
	c_q = 16'hxxxx;
	c_q <= #(10.0) sram_mem[c_a];
end
always @(c_q or c_oe_n or c_we_n) begin
	q_b <= #(T_IN) c_q;
	q_oe <= #(T_IN) ~c_oe_n & c_we_n;
end
assign md[7:0] = q_oe[0] ? q_b[7:0] : 8'bz;
assign md[15:8] = q_oe[1] ? q_b[15:8] : 8'bz;

// ---- the expected memory (small address ranges)
reg [7:0] vram_lo [0:63], vram_hi [0:63];
reg [7:0] aram_m [0:127], bsram_m [0:127];
reg vram_v [0:63];
reg aram_v [0:127], bsram_v [0:127];
integer reads = 0, writes = 0, retoggles = 0, words16 = 0;
integer i;

function [14:0] va;
	input [5:0] n;
	begin va = {n[5:3], 6'd0, n[2:0], 3'd0}; end
endfunction
function [15:0] aa;
	input [6:0] n;
	begin aa = {n[6:4], 6'd0, n[3:1], 3'd0, n[0]}; end // n and n ^ 1: the bytes of one word
endfunction
function [19:0] ba;
	input [6:0] n;
	begin ba = {n[6:4], 10'd0, n[3:1], 3'd0, n[0]}; end
endfunction

task fail;
	input [8*16-1:0] port;
	input [31:0] addr, got, exp;
	begin
		errors = errors + 1;
		if (errors < 20) $display("%t: %0s read %h: %h, expected %h", $time, port, addr, got, exp);
	end
endtask

// vram: one thread for both halves, the halves at the same address most of the time
task vram_access;
	input [5:0] n1, n2;
	input we1, we2, do1, do2;
	input [7:0] d1, d2;
	begin
		@(negedge clk_sys);
		if (do1) begin v1_addr <= va(n1); v1_we <= we1; v1_din <= d1; v1_req <= ~v1_req; end
		if (do2) begin v2_addr <= va(n2); v2_we <= we2; v2_din <= d2; v2_req <= ~v2_req; end
		if (do1 && do2 && n1 == n2 && we1 == we2) words16 = words16 + 1;
		@(posedge clk_sys);
		while (v1_req != v1_ack || dut.vram1_open || dut.busy[2] || v2_req != v2_ack || dut.vram2_open || dut.busy[3])
			@(posedge clk_sys);
		if (do1) begin
			if (we1) begin vram_lo[n1] = d1; writes = writes + 1; end
			else if (vram_v[n1]) begin reads = reads + 1; if (v1_dout !== vram_lo[n1]) fail("vram1", va(n1), v1_dout, vram_lo[n1]); end
		end
		if (do2) begin
			if (we2) begin vram_hi[n2] = d2; writes = writes + 1; end
			else if (vram_v[n2]) begin reads = reads + 1; if (v2_dout !== vram_hi[n2]) fail("vram2", va(n2), v2_dout, vram_hi[n2]); end
		end
	end
endtask

task aram_access;
	input [6:0] n;
	input we, retoggle;
	input [6:0] n2;
	input [7:0] d;
	reg [6:0] nn;
	begin
		@(negedge clk_sys);
		a_addr <= aa(n); a_we <= we; a_din <= d; a_req <= ~a_req;
		nn = n;
		if (retoggle && !we) begin
			@(negedge clk_sys);
			if (a_req != a_ack || dut.aram_open || dut.busy[4]) begin
				a_addr <= aa(n2); a_req <= ~a_req; nn = n2; retoggles = retoggles + 1;
			end
		end
		@(posedge clk_sys);
		while (a_req != a_ack || dut.aram_open || dut.busy[4]) @(posedge clk_sys);
		if (we) begin aram_m[n] = d; aram_v[n] = 1'b1; writes = writes + 1; end
		else if (aram_v[nn] && aram_v[nn ^ 7'd1]) begin
			// the word: the even byte low, the odd byte high
			reads = reads + 1;
			if (a_dout !== (nn[0] ? {aram_m[nn], aram_m[nn ^ 7'd1]} : {aram_m[nn ^ 7'd1], aram_m[nn]}))
				fail("aram", aa(nn), a_dout, nn[0] ? {aram_m[nn], aram_m[nn ^ 7'd1]} : {aram_m[nn ^ 7'd1], aram_m[nn]});
		end
	end
endtask

task bsram_access;
	input [6:0] n;
	input we;
	input [7:0] d;
	begin
		@(negedge clk_sys);
		b_addr <= ba(n); b_we <= we; b_din <= d; b_req <= ~b_req;
		@(posedge clk_sys);
		while (b_req != b_ack || dut.bsram_open || dut.busy[5]) @(posedge clk_sys);
		if (we) begin bsram_m[n] = d; bsram_v[n] = 1'b1; writes = writes + 1; end
		else if (bsram_v[n] && bsram_v[n ^ 7'd1]) begin
			reads = reads + 1;
			if (b_dout !== (n[0] ? {bsram_m[n], bsram_m[n ^ 7'd1]} : {bsram_m[n ^ 7'd1], bsram_m[n]}))
				fail("bsram", ba(n), b_dout, n[0] ? {bsram_m[n], bsram_m[n ^ 7'd1]} : {bsram_m[n ^ 7'd1], bsram_m[n]});
		end
	end
endtask

// io: reads of the aram area as words (the loader port sees the same memory)
task io_read_aram;
	input [6:0] n;
	reg [6:0] e;
	begin
		e = {n[6:1], 1'b0};
		@(negedge clk_sys);
		// the byte address of the aram area (word 008000)
		i_addr <= {5'd0, 1'b1, aa(e)}; i_word <= 1'b1; i_we <= 1'b0; i_req <= ~i_req;
		@(posedge clk_sys);
		while (i_req != i_ack || dut.io_open || dut.busy[6]) @(posedge clk_sys);
		if (aram_v[e] && aram_v[e + 7'd1]) begin
			reads = reads + 1;
			if (i_dout !== {aram_m[e + 7'd1], aram_m[e]}) fail("io", i_addr, i_dout, {aram_m[e + 7'd1], aram_m[e]});
		end
	end
endtask

// an answer must change at ph 0 only
reg [7:0] v1_d, v2_d;
reg [15:0] a_d, b_d, i_d;
reg [4:0] acks_d;
always @(posedge clk_mem) begin
	{v1_d, v2_d, a_d, b_d, i_d} <= {v1_dout, v2_dout, a_dout, b_dout, i_dout};
	acks_d <= {v1_ack, v2_ack, a_ack, b_ack, i_ack};
	if (({v1_d, v2_d, a_d, b_d, i_d} != {v1_dout, v2_dout, a_dout, b_dout, i_dout} ||
	     acks_d != {v1_ack, v2_ack, a_ack, b_ack, i_ack}) && phase.ph != 2'd1) begin
		errors = errors + 1;
		if (errors < 20) $display("%t: an answer changed at ph %0d", $time, phase.ph - 2'd1);
	end
end

// watchdog: an open request without an answer for 1000 clk_sys (a lost request)
integer quiet = 0;
reg [4:0] wd_acks;
always @(posedge clk_sys) begin
	wd_acks <= {v1_ack, v2_ack, a_ack, b_ack, i_ack};
	if (wd_acks != {v1_ack, v2_ack, a_ack, b_ack, i_ack}) quiet = 0; else quiet = quiet + 1;
	if (quiet > 1000) begin
		$display("%t: no answer for 1000 clk_sys", $time);
		$display("tb_sram: %0d errors", errors + 1);
		$finish;
	end
end

integer seed = 5;
integer kv, ka, kb, ki;
reg [31:0] rv, ra, rb, ri;

initial begin
	for (i = 0; i < 64; i = i + 1) vram_v[i] = 1'b0;
	for (i = 0; i < 128; i = i + 1) begin aram_v[i] = 1'b0; bsram_v[i] = 1'b0; end
	repeat (4) @(posedge clk_sys);
	for (i = 0; i < 64; i = i + 1) begin
		vram_access(i, i, 1'b1, 1'b1, 1'b1, 1'b1, $random(seed), $random(seed));
		vram_v[i] = 1'b1;
	end
	for (i = 0; i < 128; i = i + 1) begin aram_access(i, 1'b1, 1'b0, 7'd0, $random(seed)); bsram_access(i, 1'b1, $random(seed)); end
	fork
		for (kv = 0; kv < N; kv = kv + 1) begin
			rv = $random(seed);
			vram_access(rv[5:0], rv[8] ? rv[5:0] : rv[14:9], rv[16] & rv[17], rv[18] & rv[19], rv[20] | rv[21], rv[22] | rv[23], $random(seed), $random(seed));
		end
		for (ka = 0; ka < N; ka = ka + 1) begin
			ra = $random(seed);
			if (ra[2:0] == 3'd0) repeat (ra[5:3]) @(posedge clk_sys);
			aram_access({ra[12] & ~(ra[13] & ra[14]), ra[11:6]}, ra[13] & ra[14], ra[15] & ra[16], ra[23:17], $random(seed));
		end
		for (kb = 0; kb < N / 2; kb = kb + 1) begin
			rb = $random(seed);
			if (rb[1:0] != 2'd0) repeat (rb[5:2]) @(posedge clk_sys);
			bsram_access(rb[12:6], rb[13] & rb[14], $random(seed));
		end
		for (ki = 0; ki < N / 4; ki = ki + 1) begin
			ri = $random(seed);
			repeat (ri[5:0]) @(posedge clk_sys);
			io_read_aram({1'b1, ri[11:6]}); // the aram thread writes n[6] = 0 only
		end
	join
	$display("tb_sram (T_OUT %0.1f, T_IN %0.1f): %0d reads, %0d writes, %0d 16-bit vram, %0d retoggles",
		T_OUT, T_IN, reads, writes, words16, retoggles);
	$display("tb_sram: %0d errors", errors);
	$finish;
end

endmodule
