`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_sdram.v

 The SDRAM of the board (MT48LC16M16A2, 4 banks x 8192 rows x 512 columns x 16 bit, 32 MB) as
 the cartridge ROM and the WRAM of the SNES. One access at a time, CAS latency 2, single reads
 and writes with auto precharge.

 Clocks: clk (clk_mem, 85.9 MHz) is 4 x clk_sys from the same PLL, phase 0; ph is 0 at the clk
 edge that is a rising clk_sys edge. SDR_CLK is clk inverted (ODDR2, as the SDRAM of tsconf):
 the commands, address and write data leave the IOB registers at a rising clk edge and the
 SDRAM takes them half a clk later.

 Read data: the SDRAM edge that takes a READ is r + T/2 + Tco (r its rising clk edge, T = 11.64 ns,
 Tco ~4 ns of the IOBs and the trace). The data are valid from that edge + CL*T + tAC (6 ns)
 + ~1.5 ns back into the FPGA, = r + 2.5T + 11.5 = r + 40.6 ns, until the next SDRAM edge + tOH
 (2.7 ns) + 1.5 ns, = r + 3.5T + 8.2 = r + 48.9 ns. The IOB registers take them at r + 4T =
 r + 46.6 ns (RD_DELAY = 4 clk after the READ): 6 ns of setup and 2.3 ns of hold with these
 delays, and a smaller Tco moves the window later by as much on both ends. RD_DELAY is a
 parameter to try 3 or 5 on hardware if the delays differ.

 Timing at 85.9 MHz (T = 11.64 ns, MT48LC16M16A2-75 / -7E): tRCD 20 ns = 2 clk (ACTIVE at c0,
 READ / WRITE at c2), tRC 66 ns = 6 clk (the next ACTIVE at c6), auto precharge of a write after
 tWR 2 clk and tRP 2 clk ends before c6 too. AUTO REFRESH: tRFC 66 ns = 6 clk. A refresh every
 7.8 us (8192 rows in 64 ms) is done between requests (a request waits at most one refresh).

 Ports (as snes_sram.v): a request is a toggle of *_req with its address, write data and we; an
 access takes the address of the last toggle, a toggle during an access asks for another one;
 the answer sets *_ack to the value of *_req at the start of the access, and *_ack and *_dout
 change at ph 0 only.
   rom:  16-bit words, rom_addr[23:1] (16 MB of ROM space), rom_ds the bytes of a write (bit 1
         the high byte = the odd address), reads give the whole word
   wram: 16-bit words, wram_addr[16:1] (128 KB at word address 800000, bank 2), a write writes
         the byte of wram_ds; the SNES side picks the byte of a read word (as rom)
 Map: word address W: bank W[23:22], row W[21:9], column W[8:0].
*/

module snes_sdram #(
	parameter RD_DELAY = 4,      // clk from READ to the edge that takes the data
	parameter INIT_WAIT = 16384  // clk before the init sequence (> 100 us at 85.9 MHz: 190 us)
) (
	input wire clk,
	input wire [1:0] ph,

	input wire rom_req,
	output reg rom_ack = 1'b0,
	input wire [23:1] rom_addr,
	input wire [15:0] rom_din,
	input wire [1:0] rom_ds,
	input wire rom_we,
	output reg [15:0] rom_dout = 16'd0,

	input wire wram_req,
	output reg wram_ack = 1'b0,
	input wire [16:1] wram_addr,
	input wire [15:0] wram_din,
	input wire [1:0] wram_ds,
	input wire wram_we,
	output reg [15:0] wram_dout = 16'd0,

	output wire ready,             // the init sequence is done

	output wire SDR_CLK,
	output reg [1:0] SDR_BA = 2'b00,
	output reg [12:0] SDR_A = 13'd0,
	output reg [1:0] SDR_DQM = 2'b11,
	output reg SDR_RAS_N = 1'b1,
	output reg SDR_CAS_N = 1'b1,
	output reg SDR_WE_N = 1'b1,
	inout wire [15:0] SDR_DQ
);

// commands {RAS, CAS, WE}
localparam CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
	CMD_PRECHARGE = 3'b010, CMD_REFRESH = 3'b001, CMD_MODE = 3'b000;
// burst 1, sequential, CL 2, single writes
localparam [12:0] MODE = 13'b000_1_00_010_0_000;

ODDR2 #(.DDR_ALIGNMENT("NONE"), .INIT(1'b0), .SRTYPE("SYNC")) sdr_clk_oddr (
	.Q(SDR_CLK), .C0(clk), .C1(~clk), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0)
);

reg [15:0] dq_out = 16'd0;
reg dq_oe = 1'b0;
assign SDR_DQ = dq_oe ? dq_out : 16'bz;
reg [15:0] dq_in = 16'd0;

task cmd;
	input [2:0] c;
	begin
		{SDR_RAS_N, SDR_CAS_N, SDR_WE_N} <= c;
	end
endtask

// init: wait, PRECHARGE ALL, 2 x AUTO REFRESH, LOAD MODE
reg [14:0] init_cnt = 15'd0;
reg init_done = 1'b0;
assign ready = init_done;

// refresh timer
reg [9:0] rfs_cnt = 10'd0;
reg rfs_pend = 1'b0;

// a port is open from a change of its req (seen at the clk edge after it) until an access takes
// its address; a change during the access opens it again (req_d: req of the previous edge)
reg rom_req_d = 1'b0, wram_req_d = 1'b0;
reg rom_pend = 1'b0, wram_pend = 1'b0;
wire rom_open = rom_pend || rom_req != rom_req_d;
wire wram_open = wram_pend || wram_req != wram_req_d;
reg rom_busy = 1'b0, wram_busy = 1'b0;
reg rom_tag = 1'b0, wram_tag = 1'b0;
reg rom_done = 1'b0, wram_done = 1'b0;

localparam S_IDLE = 2'd0, S_ACC = 2'd1, S_RFS = 2'd2;
reg [1:0] state = S_IDLE;
reg [2:0] c = 3'd0;          // clk of the access
reg acc_rom = 1'b0;          // the access is of the rom port (else wram)
reg acc_we = 1'b0;
reg [8:0] acc_col = 9'd0;
reg [15:0] acc_din = 16'd0;
reg [1:0] acc_ds = 2'b00;

reg [RD_DELAY:0] rd_pipe = 0; // a READ was issued that many clk ago
reg rd_rom = 1'b0;
reg [15:0] r_rom = 16'd0;
reg [15:0] r_wram = 16'd0;

wire start_rom = state == S_IDLE && init_done && rom_open && !rom_busy;
wire start_wram = state == S_IDLE && init_done && !start_rom && wram_open && !wram_busy;
wire start_rfs = state == S_IDLE && init_done && !start_rom && !start_wram && rfs_pend;

// word address of a request
wire [23:0] w_rom = {1'b0, rom_addr};
wire [23:0] w_wram = {8'h80, wram_addr};

always @(posedge clk) begin
	rom_req_d <= rom_req;
	wram_req_d <= wram_req;
	rom_pend <= rom_open && !start_rom;
	wram_pend <= wram_open && !start_wram;

	dq_in <= SDR_DQ;
	cmd(CMD_NOP);
	SDR_DQM <= 2'b11;
	dq_oe <= 1'b0;
	rd_pipe <= {rd_pipe[RD_DELAY-1:0], 1'b0};

	if (rfs_cnt == 10'd660) begin
		rfs_cnt <= 10'd0;
		rfs_pend <= 1'b1;
	end else
		rfs_cnt <= rfs_cnt + 10'd1;

	if (!init_done) begin
		init_cnt <= init_cnt + 15'd1;
		case (init_cnt)
			INIT_WAIT: begin cmd(CMD_PRECHARGE); SDR_A[10] <= 1'b1; end
			INIT_WAIT + 4: cmd(CMD_REFRESH);
			INIT_WAIT + 12: cmd(CMD_REFRESH);
			INIT_WAIT + 20: begin cmd(CMD_MODE); SDR_BA <= 2'b00; SDR_A <= MODE; end
			INIT_WAIT + 24: init_done <= 1'b1;
			default: ;
		endcase
	end

	case (state)
		S_IDLE: begin
			c <= 3'd1;
			if (start_rom || start_wram) begin
				state <= S_ACC;
				acc_rom <= start_rom;
				cmd(CMD_ACTIVE);
				if (start_rom) begin
					{SDR_BA, SDR_A} <= w_rom[23:9];
					acc_col <= w_rom[8:0];
					acc_we <= rom_we;
					acc_din <= rom_din;
					acc_ds <= rom_ds;
					rom_busy <= 1'b1;
					rom_tag <= rom_req;
				end else begin
					{SDR_BA, SDR_A} <= w_wram[23:9];
					acc_col <= w_wram[8:0];
					acc_we <= wram_we;
					acc_din <= wram_din;
					acc_ds <= wram_ds;
					wram_busy <= 1'b1;
					wram_tag <= wram_req;
				end
			end else if (start_rfs) begin
				state <= S_RFS;
				rfs_pend <= 1'b0;
				cmd(CMD_REFRESH);
			end
		end
		S_ACC: begin
			c <= c + 3'd1;
			if (c == 3'd2) begin
				cmd(acc_we ? CMD_WRITE : CMD_READ);
				SDR_A <= {2'b00, 1'b1, 1'b0, acc_col}; // A10: auto precharge
				if (acc_we) begin
					SDR_DQM <= ~acc_ds;
					dq_out <= acc_din;
					dq_oe <= 1'b1;
				end else begin
					SDR_DQM <= 2'b00;
					rd_pipe[0] <= 1'b1;
					rd_rom <= acc_rom;
				end
			end
			if (c == 3'd5) begin
				state <= S_IDLE; // the next ACTIVE at c6
				if (acc_we) begin
					if (acc_rom) rom_done <= 1'b1; else wram_done <= 1'b1;
				end
			end
		end
		S_RFS: begin
			c <= c + 3'd1;
			if (c == 3'd5) state <= S_IDLE;
		end
		default: state <= S_IDLE;
	endcase

	// read data: dq_in holds the data taken RD_DELAY clk after the READ
	if (rd_pipe[RD_DELAY]) begin
		if (rd_rom) begin r_rom <= dq_in; rom_done <= 1'b1; end
		else begin r_wram <= dq_in; wram_done <= 1'b1; end
	end

	// answers at ph 0; a result of this edge waits for the next ph 0
	if (ph == 2'd0) begin
		if (rom_done) begin
			rom_dout <= r_rom;
			rom_ack <= rom_tag;
			rom_busy <= start_rom;
			rom_done <= 1'b0;
		end
		if (wram_done) begin
			wram_dout <= r_wram;
			wram_ack <= wram_tag;
			wram_busy <= start_wram;
			wram_done <= 1'b0;
		end
	end
end

endmodule
