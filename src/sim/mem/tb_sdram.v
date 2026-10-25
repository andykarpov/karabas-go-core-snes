`timescale 1ns / 1ps

// snes_sdram against sdram_model with the delays of the board: commands, address, write data
// and SDR_CLK reach the SDRAM T_OUT after the FPGA registers, the read data come back T_IN
// after the SDRAM drives them. The rom and wram ports are driven from clk_sys as the SNES side
// does (requests at the falling clk_sys edge, sometimes a second toggle with a new address
// before the answer), every read is checked against a model of the memory, every answer is
// checked to change at a ph 0 edge only. Also: the refresh rate and the SDRAM timing (in the
// model).

module tb_sdram;

parameter real T_OUT = 4.0;
parameter real T_IN = 1.5;
parameter integer RD_DELAY = 4;
parameter integer N = 20000;

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

reg rom_req = 1'b0, wram_req = 1'b0;
wire rom_ack, wram_ack;
reg [23:1] rom_addr = 0;
reg [15:0] rom_din = 0;
reg [1:0] rom_ds = 0;
reg rom_we = 0;
wire [15:0] rom_dout;
reg [16:1] wram_addr = 0;
reg [15:0] wram_din = 0;
reg [1:0] wram_ds = 0;
reg wram_we = 0;
wire [15:0] wram_dout;
wire ready;

wire sdr_clk;
wire [1:0] sdr_ba, sdr_dqm;
wire [12:0] sdr_a;
wire sdr_ras_n, sdr_cas_n, sdr_we_n;
wire [15:0] dq_fpga, dq_mem;

snes_sdram #(.RD_DELAY(RD_DELAY), .INIT_WAIT(64)) dut(
	.clk(clk_mem), .ph(ph),
	.rom_req(rom_req), .rom_ack(rom_ack), .rom_addr(rom_addr), .rom_din(rom_din), .rom_ds(rom_ds),
	.rom_we(rom_we), .rom_dout(rom_dout),
	.wram_req(wram_req), .wram_ack(wram_ack), .wram_addr(wram_addr), .wram_din(wram_din),
	.wram_ds(wram_ds), .wram_we(wram_we), .wram_dout(wram_dout),
	.ready(ready),
	.SDR_CLK(sdr_clk), .SDR_BA(sdr_ba), .SDR_A(sdr_a), .SDR_DQM(sdr_dqm),
	.SDR_RAS_N(sdr_ras_n), .SDR_CAS_N(sdr_cas_n), .SDR_WE_N(sdr_we_n), .SDR_DQ(dq_fpga)
);

// the board: everything from the FPGA arrives T_OUT later, the read data T_IN later (transport
// delays: an assign with a delay would swallow the pulses of SDR_CLK shorter than it)
reg m_clk = 1'b0, m_ras_n = 1'b1, m_cas_n = 1'b1, m_we_n = 1'b1, f_oe = 1'b0, m_oe = 1'b0;
reg [1:0] m_ba = 2'b00, m_dqm = 2'b11;
reg [12:0] m_a = 13'd0;
reg [15:0] f_dq = 16'd0, m_dq = 16'd0;
always @(sdr_clk) m_clk <= #(T_OUT) sdr_clk;
always @(sdr_ba or sdr_dqm or sdr_a or sdr_ras_n or sdr_cas_n or sdr_we_n or dut.dq_oe or dut.dq_out) begin
	m_ba <= #(T_OUT) sdr_ba;
	m_dqm <= #(T_OUT) sdr_dqm;
	m_a <= #(T_OUT) sdr_a;
	{m_ras_n, m_cas_n, m_we_n} <= #(T_OUT) {sdr_ras_n, sdr_cas_n, sdr_we_n};
	f_oe <= #(T_OUT) dut.dq_oe;
	f_dq <= #(T_OUT) dut.dq_out;
end
always @(model.doe or model.dout) begin
	m_oe <= #(T_IN) model.doe;
	m_dq <= #(T_IN) model.dout;
end
assign dq_mem = f_oe ? f_dq : 16'bz;
assign dq_fpga = m_oe ? m_dq : 16'bz;

sdram_model model(.clk(m_clk), .ba(m_ba), .a(m_a), .dqm(m_dqm), .ras_n(m_ras_n), .cas_n(m_cas_n),
	.we_n(m_we_n), .dq(dq_mem));

// the expected memory: small address ranges, so that reads find written words
reg [15:0] rom_mem [0:255];
reg [15:0] wram_mem [0:255];
reg rom_valid [0:255];
reg wram_valid [0:255];
integer errors = 0;
integer reads = 0, writes = 0, retoggles = 0;
integer i;

// an answer must change at ph 0 only
reg rom_ack_d = 1'b0, wram_ack_d = 1'b0;
reg [15:0] rom_dout_d = 0, wram_dout_d = 0;
always @(posedge clk_mem) begin
	rom_ack_d <= rom_ack; wram_ack_d <= wram_ack;
	rom_dout_d <= rom_dout; wram_dout_d <= wram_dout;
	if ((rom_ack != rom_ack_d || rom_dout != rom_dout_d || wram_ack != wram_ack_d ||
	     wram_dout != wram_dout_d) && phase.ph != 2'd1) begin
		// the registers changed at the previous edge, which must have been ph 0
		errors = errors + 1;
		if (errors < 20) $display("%t: an answer changed at ph %0d", $time, phase.ph - 2'd1);
	end
end

function [23:1] rom_a;
	input [7:0] n;
	begin
		// spread over banks 0 and 1 and many rows and columns
		rom_a = {1'b0, n[7], n[6:4], 9'd0, n[3:0], 5'd0} ^ {n[3:0], 18'd0};
	end
endfunction

function [16:1] wram_a;
	input [7:0] n;
	begin
		wram_a = {n[7:4], 4'd0, n[3:0], 4'd0};
	end
endfunction

// one request of a port, the way the SNES side makes them; returns when it is answered: ack
// equal to req and nothing open or being served (the SNES side does not wait, the test needs to)
task rom_access;
	input [7:0] n;
	input we;
	input [1:0] ds;
	input [15:0] d;
	input retoggle;
	input [7:0] n2;
	reg [7:0] nn;
	begin
		@(negedge clk_sys);
		rom_addr <= rom_a(n); rom_we <= we; rom_ds <= ds; rom_din <= d;
		rom_req <= ~rom_req;
		nn = n;
		if (retoggle && !we) begin
			// a new address before the answer (a read only)
			@(negedge clk_sys);
			if (rom_req != rom_ack || dut.rom_open || dut.rom_busy) begin
				rom_addr <= rom_a(n2);
				rom_req <= ~rom_req;
				nn = n2;
				retoggles = retoggles + 1;
			end
		end
		@(posedge clk_sys);
		while (rom_req != rom_ack || dut.rom_open || dut.rom_busy) @(posedge clk_sys);
		if (we) begin
			if (ds[0]) rom_mem[n][7:0] = d[7:0];
			if (ds[1]) rom_mem[n][15:8] = d[15:8];
			rom_valid[n] = 1'b1;
			writes = writes + 1;
		end else if (rom_valid[nn]) begin
			reads = reads + 1;
			if (rom_dout !== rom_mem[nn]) begin
				errors = errors + 1;
				if (errors < 20) $display("%t: rom read %h: %h, expected %h (n %h nn %h)", $time, rom_a(nn), rom_dout, rom_mem[nn], n, nn);
			end
		end
	end
endtask

task wram_access;
	input [7:0] n;
	input we;
	input [1:0] ds;
	input [15:0] d;
	begin
		@(negedge clk_sys);
		wram_addr <= wram_a(n); wram_we <= we; wram_ds <= ds; wram_din <= d;
		wram_req <= ~wram_req;
		@(posedge clk_sys);
		while (wram_req != wram_ack || dut.wram_open || dut.wram_busy) @(posedge clk_sys);
		if (we) begin
			if (ds[0]) wram_mem[n][7:0] = d[7:0];
			if (ds[1]) wram_mem[n][15:8] = d[15:8];
			wram_valid[n] = 1'b1;
			writes = writes + 1;
		end else if (wram_valid[n]) begin
			reads = reads + 1;
			if (wram_dout !== wram_mem[n]) begin
				errors = errors + 1;
				if (errors < 20) $display("%t: wram read %h: %h, expected %h", $time, wram_a(n), wram_dout, wram_mem[n]);
			end
		end
	end
endtask

// watchdog: an open request without an answer for 1000 clk_sys (a lost request)
integer quiet = 0;
reg [1:0] wd_acks;
always @(posedge clk_sys) begin
	wd_acks <= {rom_ack, wram_ack};
	if (wd_acks != {rom_ack, wram_ack}) quiet = 0; else quiet = quiet + 1;
	if (quiet > 1000) begin
		$display("%t: no answer for 1000 clk_sys", $time);
		$display("tb_sdram: %0d errors", errors + 1);
		$finish;
	end
end

integer seed = 1;
integer k;
reg [31:0] r, r2;

initial begin
	for (i = 0; i < 256; i = i + 1) begin rom_valid[i] = 1'b0; wram_valid[i] = 1'b0; end
	wait (ready);
	// fill both, whole words
	for (i = 0; i < 256; i = i + 1) begin
		rom_access(i, 1'b1, 2'b11, $random(seed), 1'b0, 8'd0);
		wram_access(i, 1'b1, 2'b11, $random(seed));
	end
	// both ports at the same time, random reads and byte writes, idle gaps
	fork
		begin : rom_side
			for (k = 0; k < N; k = k + 1) begin
				r = $random(seed);
				if (r[3:0] == 4'd0) repeat (r[7:4]) @(posedge clk_sys);
				rom_access(r[15:8], r[16] & r[17], r[19:18] == 2'b00 ? 2'b11 : r[19:18], $random(seed), r[20] & r[21], r[31:24]);
			end
		end
		begin : wram_side
			for (i = 0; i < N; i = i + 1) begin
				r2 = $random(seed);
				if (r2[3:0] < 4'd3) repeat (r2[7:4]) @(posedge clk_sys);
				wram_access(r2[15:8], r2[16], r2[19:18] == 2'b00 ? 2'b11 : r2[19:18], $random(seed));
			end
		end
	join
	model.check_refresh;
	errors = errors + model.errors;
	$display("tb_sdram (T_OUT %0.1f, T_IN %0.1f, RD_DELAY %0d): %0d reads, %0d writes, %0d retoggles, %0d refreshes",
		T_OUT, T_IN, RD_DELAY, reads, writes, retoggles, model.refreshes);
	$display("tb_sdram: %0d errors", errors);
	$finish;
end

endmodule
