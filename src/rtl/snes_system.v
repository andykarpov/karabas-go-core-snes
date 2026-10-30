`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_system.v

 The SNES of the three boards: main of SNES_FPGA (rtl/snes), its memories (snes_sdram: ROM and
 WRAM; snes_sram: VRAM, ARAM, BSRAM), the ROM loader of the MCU link, the header detection
 (snes_hdr) and the controllers (snes_joy). The tops add the clocks, the MCU link, video and
 audio outputs.

 Clocks: clk_sys = the master clock of the SNES (21.48 MHz), clk_mem = 4 x clk_sys of the same
 PLL, phase 0 (snes_phase gives the phase).

 The requests to the memories are made at the falling clk_sys edge as in SNES.sv of the MiST
 core (the branch without BRAM_LEVEL_1 and BRAM_ARAM): a new request when the address of a read
 changes and at the start of a write; ROM, WRAM, ARAM and BSRAM read 16-bit words and the byte
 is picked with address bit 0 of the moment.

 Load (FILELOAD_* of kg_mcu, FILE_CMDS 1): while load_active the SNES is in reset and the bytes
 go to the ROM area of the SDRAM at their file offset (through a small fifo: a byte can come
 before the write of the one before it is done); then snes_hdr finds the header and the
 offset of a copier header, which is added to the ROM addresses of the SNES.
*/

module snes_system #(
	parameter USE_DSPN = 0
) (
	input wire clk_sys,
	input wire clk_mem,

	input wire reset,               // OSD / keyboard reset (level)
	input wire [1:0] rom_sel,       // 0 auto, 1 LoROM, 2 HiROM, 3 ExHiROM
	input wire [1:0] region_sel,    // 0 auto (NTSC), 1 NTSC, 2 PAL

	input wire load_active,
	input wire [31:0] load_addr,
	input wire [7:0] load_data,
	input wire load_wr,

	input wire [11:0] pad1,          // snes_joy order, 1 = pressed
	input wire [11:0] pad2,

	output wire [7:0] R,
	output wire [7:0] G,
	output wire [7:0] B,
	output wire HSYNC,
	output wire VSYNC,
	output wire HBLANKn,
	output wire VBLANKn,
	output wire pal,
	output wire [15:0] audio_l,
	output wire [15:0] audio_r,
	output wire audio_lrck,         // a period per sample, the sample changes in its high half
	output wire running,            // not in reset (for the OSD / debug)

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire SDR_CLK,
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire [1:0] SDR_DQM,
	output wire SDR_RAS_N,
	output wire SDR_CAS_N,
	output wire SDR_WE_N,
	inout wire [15:0] SDR_DQ
);

wire [1:0] ph;
snes_phase phase(.clk_sys(clk_sys), .clk_mem(clk_mem), .ph(ph));

// ------------------------------------------------------------------------------------------
// load and header

wire ld_empty, ld_full;
wire [31:0] ld_q;
reg ld_rd = 1'b0;
kg_fifo #(.DW(32), .AW(4)) load_fifo(
	.clk(clk_sys), .reset(1'b0),
	.wr(load_wr && load_active), .din({load_addr[23:0], load_data}), .full(ld_full),
	.rd(ld_rd), .dout(ld_q), .empty(ld_empty), .count()
);

reg load_d = 1'b0;
reg load_end = 1'b0;         // the load is over, its last bytes may still be in the fifo
reg [23:0] load_size = 24'd0;
reg ld_busy = 1'b0;          // a write of the fifo is in the SDRAM
reg ld_valid = 1'b0;         // ld_q holds a byte to write
reg hdr_start = 1'b0;

wire hdr_busy;
wire hdr_req;
wire [23:1] hdr_addr;
wire [1:0] lhrom;
wire hdr_off;
wire [7:0] h_map, h_type, h_region, h_company;
wire [3:0] h_rom_size, h_ram_size;
wire rom_ack, hdr_ack;
wire [15:0] rom_dout;

snes_hdr hdr(
	.clk(clk_sys), .start(hdr_start), .size(load_size), .sel(rom_sel), .busy(hdr_busy),
	.rom_req(hdr_req), .rom_ack(hdr_ack), .rom_addr(hdr_addr), .rom_dout(rom_dout),
	.lhrom(lhrom), .hdr_off(hdr_off), .map(h_map), .rtype(h_type), .rom_size(h_rom_size),
	.ram_size(h_ram_size), .region(h_region), .company(h_company)
);

// ------------------------------------------------------------------------------------------
// cartridge type: SNES.sv of MiST (ROM DETECT), from the header found

reg [7:0] rom_type = 8'd0;

function [23:0] mask_of;
	input [3:0] n;
	begin
		case (n)
			4'd0: mask_of = 24'h0003FF;
			4'd1: mask_of = 24'h0007FF;
			4'd2: mask_of = 24'h000FFF;
			4'd3: mask_of = 24'h001FFF;
			4'd4: mask_of = 24'h003FFF;
			4'd5: mask_of = 24'h007FFF;
			4'd6: mask_of = 24'h00FFFF;
			4'd7: mask_of = 24'h01FFFF;
			4'd8: mask_of = 24'h03FFFF;
			4'd9: mask_of = 24'h07FFFF;
			4'd10: mask_of = 24'h0FFFFF;
			4'd11: mask_of = 24'h1FFFFF;
			4'd12: mask_of = 24'h3FFFFF;
			4'd13: mask_of = 24'h7FFFFF;
			default: mask_of = 24'hFFFFFF; // 1024 << 14 and more wrap to 0 in 24 bits: 0 - 1
		endcase
	end
endfunction
reg [23:0] rom_mask = 24'd0, ram_mask = 24'd0;
reg pal_r = 1'b0;
reg pal_id = 1'b0;
assign pal = pal_r;

always @(posedge clk_sys) begin
	// (1024 << size) - 1 of SNES.sv as a table (a variable 24-bit shift is two barrel shifters)
	rom_mask <= mask_of((h_rom_size < 4'd7) ? 4'hC : h_rom_size);
	ram_mask <= h_ram_size ? mask_of(h_ram_size) : 24'd0;
	// karabas: the timing is NTSC on auto, also for a PAL cartridge: a monitor that shows 60 Hz
	// only gets 640 x 480 always; a PAL game runs ~20 % fast. PAL (576p) only when chosen in the OSD.
	pal_r <= region_sel == 2'd2;
	// the region the game sees in $213F: of the header on auto, so a PAL game on the NTSC timing
	// does not stop at its "not designed for your SUPER NES" screen (as a 50/60 Hz switch mod)
	pal_id <= region_sel == 2'd2 ? 1'b1 : region_sel == 2'd1 ? 1'b0 :
		(h_region >= 8'h02 && h_region <= 8'h0C) || h_region == 8'h11;

	rom_type <= {6'd0, lhrom};
	//DSP3
	if (h_map == 8'h30 && h_type == 8'd5 && h_company == 8'hB2) rom_type[7:4] <= 4'hA;
	//DSP1
	else if (((h_map == 8'h20 || h_map == 8'h21) && h_type == 8'd3) ||
	    (h_map == 8'h30 && h_type == 8'd5) ||
	    (h_map == 8'h31 && (h_type == 8'd3 || h_type == 8'd5))) rom_type[7] <= 1'b1;
	//DSP2
	else if (h_map == 8'h20 && h_type == 8'd5) rom_type[7:4] <= 4'h9;
	//DSP4
	else if (h_map == 8'h30 && h_type == 8'd3) rom_type[7:4] <= 4'hB;
	//OBC1
	else if (h_map == 8'h30 && h_type == 8'h25) rom_type[7:4] <= 4'hC;
	//ST0XX
	else if (h_map == 8'h30 && h_type == 8'hf6) begin
		rom_type[7:3] <= {4'h8, 1'b1};
		if (h_rom_size < 4'd10) rom_type[5] <= 1'b1; // Hayazashi Nidan Morita Shougi
	end
	// karabas: the GSU, SA1, SPC7110, CX4 and SDD1 cases are left out: no such chips in this core
end

// ------------------------------------------------------------------------------------------
// reset: held while loading, finding the header and until the SDRAM is ready

wire sdram_ready;
reg RESET_N = 1'b0;
reg [1:0] div = 2'd0;
wire hold = reset || load_active || load_end || hdr_start || hdr_busy || !sdram_ready;
always @(posedge clk_sys) begin
	div <= div + 2'd1;
	if (div == 2'd2) RESET_N <= ~hold;
end
assign running = RESET_N;

// ------------------------------------------------------------------------------------------
// main

wire [23:0] ROM_ADDR, ROM_ADDR_EARLY;
wire [15:0] ROM_D, ROM_Q;
wire ROM_CE_N, ROM_OE_N, ROM_WE_N, ROM_WORD;
wire [19:0] BSRAM_ADDR;
wire [7:0] BSRAM_D, BSRAM_Q;
wire BSRAM_CE_N, BSRAM_OE_N, BSRAM_WE_N, BSRAM_RD_N;
wire [16:0] WRAM_ADDR;
wire [7:0] WRAM_D, WRAM_Q;
wire WRAM_CE_N, WRAM_OE_N, WRAM_WE_N, WRAM_RD_N;
wire [15:0] VRAM1_ADDR, VRAM2_ADDR;
wire [7:0] VRAM1_D, VRAM2_D, VRAM1_Q, VRAM2_Q;
wire VRAM1_WE_N, VRAM2_WE_N, VRAM_OE_N;
wire [15:0] ARAM_ADDR;
wire [7:0] ARAM_D, ARAM_Q;
wire ARAM_CE_N, ARAM_OE_N, ARAM_WE_N;
wire SYSCLKF_CE, SYSCLKR_CE, REFRESH, DOT_CLK_CE;
wire JOY_STRB, JOY1_CLK, JOY2_CLK;
wire [1:0] JOY1_DO, JOY2_DO;

main #(
	.USE_DLH(1), .USE_CX4(0), .USE_SDD1(0), .USE_GSU(0), .USE_SA1(0), .USE_DSPn(USE_DSPN),
	.USE_SPC7110(0), .USE_BSX(0), .USE_SUFAMI(0), .USE_MSU(0), .USE_SS(0)
) main(
	.RESET_N(RESET_N),
	.MCLK(clk_sys),
	.ACLK(clk_sys),
	.HALT(1'b0),

	.ROM_TYPE(rom_type),
	.ROM_MASK(rom_mask),
	.RAM_MASK(ram_mask),
	.RAM_SIZE(h_ram_size),

	.SYSCLKR_CE(SYSCLKR_CE),
	.SYSCLKF_CE(SYSCLKF_CE),
	.REFRESH(REFRESH),

	.ROM_ADDR(ROM_ADDR),
	.ROM_ADDR_EARLY(ROM_ADDR_EARLY),
	.ROM_D(ROM_D),
	.ROM_Q(ROM_Q),
	.ROM_CE_N(ROM_CE_N),
	.ROM_OE_N(ROM_OE_N),
	.ROM_WE_N(ROM_WE_N),
	.ROM_WORD(ROM_WORD),

	.BSRAM_ADDR(BSRAM_ADDR),
	.BSRAM_D(BSRAM_D),
	.BSRAM_Q(BSRAM_Q),
	.BSRAM_CE_N(BSRAM_CE_N),
	.BSRAM_OE_N(BSRAM_OE_N),
	.BSRAM_WE_N(BSRAM_WE_N),
	.BSRAM_RD_N(BSRAM_RD_N),

	.WRAM_ADDR(WRAM_ADDR),
	.WRAM_D(WRAM_D),
	.WRAM_Q(WRAM_Q),
	.WRAM_CE_N(WRAM_CE_N),
	.WRAM_OE_N(WRAM_OE_N),
	.WRAM_WE_N(WRAM_WE_N),
	.WRAM_RD_N(WRAM_RD_N),

	.VRAM1_ADDR(VRAM1_ADDR),
	.VRAM1_DI(VRAM1_Q),
	.VRAM1_DO(VRAM1_D),
	.VRAM1_WE_N(VRAM1_WE_N),
	.VRAM2_ADDR(VRAM2_ADDR),
	.VRAM2_DI(VRAM2_Q),
	.VRAM2_DO(VRAM2_D),
	.VRAM2_WE_N(VRAM2_WE_N),
	.VRAM_OE_N(VRAM_OE_N),

	.ARAM_ADDR(ARAM_ADDR),
	.ARAM_D(ARAM_D),
	.ARAM_Q(ARAM_Q),
	.ARAM_CE_N(ARAM_CE_N),
	.ARAM_OE_N(ARAM_OE_N),
	.ARAM_WE_N(ARAM_WE_N),

	.GSU_ACTIVE(),
	.GSU_TURBO(1'b0),
	.GSU_FASTROM(1'b0),
	.SUFAMI_SWAP(1'b0),

	.BLEND(1'b0),
	.PAL(pal_r),
	.PAL_ID(pal_id),
	.DIS_SHORTLINE(1'b0),
	.HIGH_RES(),
	.FIELD(),
	.INTERLACE(),
	.DOTCLK(),
	.R(R),
	.G(G),
	.B(B),
	.HBLANKn(HBLANKn),
	.VBLANKn(VBLANKn),
	.HSYNC(HSYNC),
	.VSYNC(VSYNC),

	.JOY1_DI(JOY1_DO),
	.JOY2_DI(JOY2_DO),
	.JOY_STRB(JOY_STRB),
	.JOY1_CLK(JOY1_CLK),
	.JOY2_CLK(JOY2_CLK),
	.JOY1_P6(),
	.JOY2_P6(),
	.JOY2_P6_in(1'b1),

	.DOT_CLK_CE(DOT_CLK_CE),
	.EXT_RTC(65'd0),

	.GG_EN(1'b0),
	.GG_CODE(129'd0),
	.GG_RESET(1'b0),
	.GG_AVAILABLE(),

	.SPC_MODE(1'b0),
	.IO_ADDR(17'd0),
	.IO_DAT(16'd0),
	.IO_WR(1'b0),

	.DBG_BG_EN(5'b11111),
	.DBG_CPU_EN(1'b1),
	.TURBO(1'b0),
	.TURBO_ALLOW(),

	.MSU_TRACK_NUM(),
	.MSU_TRACK_REQUEST(),
	.MSU_TRACK_MOUNTING(1'b0),
	.MSU_TRACK_MISSING(1'b0),
	.MSU_VOLUME(),
	.MSU_AUDIO_STOP(1'b0),
	.MSU_AUDIO_REPEAT(),
	.MSU_AUDIO_PLAYING(),
	.MSU_DATA_ADDR(),
	.MSU_DATA(8'd0),
	.MSU_DATA_ACK(1'b0),
	.MSU_DATA_SEEK(),
	.MSU_DATA_REQ(),
	.MSU_ENABLE(1'b0),

	.SS_SAVE(1'b0),
	.SS_TOSD(1'b0),
	.SS_LOAD(1'b0),
	.SS_SLOT(2'd0),
	.SS_AVAIL(),
	.SS_DDR_DI(64'd0),
	.SS_DDR_ACK(1'b0),
	.SS_DDR_DO(),
	.SS_DDR_ADDR(),
	.SS_DDR_WE(),
	.SS_DDR_BE(),
	.SS_DDR_REQ(),

	.AUDIO_L(audio_l),
	.AUDIO_R(audio_r),
	.LRCK(audio_lrck)
);

snes_joy joy1(.clk(clk_sys), .pad(pad1), .strobe(JOY_STRB), .port_clk(JOY1_CLK), .port_do(JOY1_DO));
snes_joy joy2(.clk(clk_sys), .pad(pad2), .strobe(JOY_STRB), .port_clk(JOY2_CLK), .port_do(JOY2_DO));

// ------------------------------------------------------------------------------------------
// requests to the memories (falling clk_sys edge, SNES.sv of MiST)

// rom: the SNES, or the loader / snes_hdr while the SNES is in reset. Each has its own toggle;
// the req of the port is their xor (one of them toggles at a time, the owner changes only while
// the others are quiet), so no owner change looks like a request. A requester is answered when
// the ack of the port equals the req of the port.
reg snes_rom_req = 1'b0;
reg [23:1] rom_addr_sd = 23'h7FFFFF;
reg ld_req = 1'b0;
reg [23:1] ld_addr = 23'd0;
reg [15:0] ld_din = 16'd0;
reg [1:0] ld_ds = 2'b00;
wire loading = !RESET_N && !hdr_busy;   // the loader owns the rom port (snes_hdr when busy)

wire rom_req = snes_rom_req ^ ld_req ^ hdr_req;
wire [23:1] rom_a = hdr_busy ? hdr_addr : !RESET_N ? ld_addr : rom_addr_sd;
wire rom_we = loading;
// (a read of the SNES still open when the reset starts is served as a write of the last loader
// byte again, the same data at the same address, or with no byte selected before the first load)
assign hdr_ack = rom_ack ^ snes_rom_req ^ ld_req; // equal to hdr_req when the port is answered

// the copier header offset is added to the ROM addresses of the SNES (in words: 100)
wire [23:1] snes_rom_a = ROM_ADDR_EARLY[23:1] + (hdr_off ? 23'h000100 : 23'h000000);

assign ROM_Q = (ROM_WORD || ~ROM_ADDR_EARLY[0]) ? rom_dout : {rom_dout[7:0], rom_dout[15:8]};

always @(negedge clk_sys) begin
	if (!RESET_N)
		rom_addr_sd <= 23'h7FFFFF;
	else if (~ROM_CE_N && rom_addr_sd != snes_rom_a) begin
		rom_addr_sd <= snes_rom_a;
		snes_rom_req <= ~snes_rom_req;
	end
end

// the loader: one byte of the fifo at a time; snes_hdr starts when the last byte is written
always @(posedge clk_sys) begin
	ld_rd <= 1'b0;
	load_d <= load_active;
	hdr_start <= 1'b0;
	if (load_active && !load_d) load_size <= 24'd0;
	if (load_d && !load_active) load_end <= 1'b1;
	if (load_end && !load_active && ld_empty && !ld_rd && !ld_valid && !ld_busy) begin
		load_end <= 1'b0;
		hdr_start <= 1'b1;
	end
	if (!loading) begin
		ld_busy <= 1'b0;
		ld_valid <= 1'b0;
	end else if (ld_busy) begin
		if (rom_ack == rom_req) ld_busy <= 1'b0;
	end else if (ld_valid) begin
		ld_valid <= 1'b0;
		ld_addr <= ld_q[31:9];
		ld_din <= {ld_q[7:0], ld_q[7:0]};
		ld_ds <= ld_q[8] ? 2'b10 : 2'b01;
		ld_req <= ~ld_req;
		ld_busy <= 1'b1;
		if (ld_q[31:8] >= load_size) load_size <= ld_q[31:8] + 24'd1;
	end else if (!ld_empty && !ld_rd) begin
		ld_rd <= 1'b1;
	end
	if (ld_rd) ld_valid <= 1'b1;
end

// wram
wire wram_rd = ~WRAM_CE_N & ~WRAM_RD_N;
wire wram_wr = ~WRAM_CE_N & ~WRAM_WE_N;
reg wram_rdD = 1'b0, wram_wrD = 1'b0;
reg wram_req = 1'b0;
reg [16:0] wram_addr_sd = 17'd0;
reg [15:0] wram_din = 16'd0;
reg [1:0] wram_ds = 2'b00;
reg wram_we = 1'b0;
wire wram_ack;
wire [15:0] wram_dout;
assign WRAM_Q = WRAM_ADDR[0] ? wram_dout[15:8] : wram_dout[7:0];

always @(negedge clk_sys) begin
	wram_rdD <= wram_rd;
	wram_wrD <= wram_wr;
	if ((wram_rd && WRAM_ADDR[16:1] != wram_addr_sd[16:1]) || (~wram_wrD & wram_wr) || (~wram_rdD & wram_rd)) begin
		wram_addr_sd <= WRAM_ADDR;
		wram_req <= ~wram_req;
		wram_we <= wram_wr;
		wram_din <= {WRAM_D, WRAM_D};
		wram_ds <= {WRAM_ADDR[0], ~WRAM_ADDR[0]};
	end
end

// bsram
wire bsram_rd = ~BSRAM_CE_N & (~BSRAM_RD_N || rom_type[7:4] == 4'hC);
wire bsram_wr = ~BSRAM_CE_N & ~BSRAM_WE_N;
reg bsram_rdD = 1'b0, bsram_wrD = 1'b0;
reg bsram_req = 1'b0;
reg [7:0] bsram_din = 8'd0;  // BSRAM_D of the last falling clk_sys edge (see below)
reg [19:0] bsram_sd_addr = 20'd0;
reg bsram_we = 1'b0;
wire bsram_ack;
wire [15:0] bsram_dout;
assign BSRAM_Q = BSRAM_ADDR[0] ? bsram_dout[15:8] : bsram_dout[7:0];

// vram
reg vram1_req = 1'b0, vram2_req = 1'b0;
reg [14:0] vram1_addr_sd = 15'h7FFF, vram2_addr_sd = 15'h7FFF;
reg [7:0] vram1_din = 8'd0, vram2_din = 8'd0;
reg vram1_we_nD = 1'b1, vram2_we_nD = 1'b1;
wire vram1_ack, vram2_ack;

// aram
wire aram_rd = ~ARAM_CE_N & ~ARAM_OE_N;
wire aram_wr = ~ARAM_CE_N & ~ARAM_WE_N;
reg aram_rd_last = 1'b0, aram_wr_last = 1'b0;
reg aram_req = 1'b0;
reg [15:0] aram_addr_sd = 16'd0;
reg [7:0] aram_din = 8'd0;
wire aram_ack;
wire [15:0] aram_dout;
assign ARAM_Q = ARAM_ADDR[0] ? aram_dout[15:8] : aram_dout[7:0];

always @(negedge clk_sys) begin
	aram_wr_last <= aram_wr;
	aram_rd_last <= aram_rd;
	if ((aram_rd && ARAM_ADDR[15:1] != aram_addr_sd[15:1]) || (aram_wr && ARAM_ADDR != aram_addr_sd) ||
	    (aram_rd & ~aram_rd_last) || (aram_wr & ~aram_wr_last)) begin
		aram_req <= ~aram_req;
		aram_addr_sd <= ARAM_ADDR;
		aram_din <= ARAM_D;
	end

	// karabas: the MiST core gives the controller BSRAM_D itself ("OBC1 doesn't like" a copy taken
	// with the request); a copy at every falling edge is the same value a little earlier, and keeps
	// the logic of the CPU out of the paths into clk_mem
	bsram_din <= BSRAM_D;

	if (RESET_N) begin
		bsram_rdD <= bsram_rd;
		bsram_wrD <= bsram_wr;
		if ((bsram_rd && BSRAM_ADDR[19:1] != bsram_sd_addr[19:1]) || (~bsram_wrD & bsram_wr) || (~bsram_rdD & bsram_rd)) begin
			bsram_req <= ~bsram_req;
			bsram_sd_addr <= BSRAM_ADDR;
			bsram_we <= bsram_wr;
		end

		vram1_we_nD <= VRAM1_WE_N;
		if ((vram1_we_nD & ~VRAM1_WE_N) || (VRAM1_ADDR[14:0] != vram1_addr_sd && ~VRAM_OE_N)) begin
			vram1_addr_sd <= VRAM1_ADDR[14:0];
			vram1_din <= VRAM1_D;
			vram1_req <= ~vram1_req;
		end

		vram2_we_nD <= VRAM2_WE_N;
		if ((vram2_we_nD & ~VRAM2_WE_N) || (VRAM2_ADDR[14:0] != vram2_addr_sd && ~VRAM_OE_N)) begin
			vram2_addr_sd <= VRAM2_ADDR[14:0];
			vram2_din <= VRAM2_D;
			vram2_req <= ~vram2_req;
		end
	end
end

// ------------------------------------------------------------------------------------------
// memories

snes_sdram sdram(
	.clk(clk_mem), .ph(ph),
	.rom_req(rom_req), .rom_ack(rom_ack), .rom_addr(rom_a), .rom_din(ld_din), .rom_ds(ld_ds),
	.rom_we(rom_we), .rom_dout(rom_dout),
	.wram_req(wram_req), .wram_ack(wram_ack), .wram_addr(wram_addr_sd[16:1]), .wram_din(wram_din),
	.wram_ds(wram_ds), .wram_we(wram_we), .wram_dout(wram_dout),
	.ready(sdram_ready),
	.SDR_CLK(SDR_CLK), .SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_DQM(SDR_DQM),
	.SDR_RAS_N(SDR_RAS_N), .SDR_CAS_N(SDR_CAS_N), .SDR_WE_N(SDR_WE_N), .SDR_DQ(SDR_DQ)
);

snes_sram sram(
	.clk(clk_mem), .ph(ph),
	.vram1_req(vram1_req), .vram1_ack(vram1_ack), .vram1_addr(vram1_addr_sd), .vram1_din(vram1_din),
	.vram1_we(~vram1_we_nD), .vram1_dout(VRAM1_Q),
	.vram2_req(vram2_req), .vram2_ack(vram2_ack), .vram2_addr(vram2_addr_sd), .vram2_din(vram2_din),
	.vram2_we(~vram2_we_nD), .vram2_dout(VRAM2_Q),
	.aram_req(aram_req), .aram_ack(aram_ack), .aram_addr(aram_addr_sd), .aram_din(aram_din),
	.aram_we(aram_wr_last), .aram_dout(aram_dout),
	.bsram_req(bsram_req), .bsram_ack(bsram_ack), .bsram_addr(bsram_sd_addr), .bsram_din(bsram_din),
	.bsram_we(bsram_we), .bsram_dout(bsram_dout),
	.io_req(1'b0), .io_ack(), .io_addr(22'd0), .io_word(1'b0), .io_din(16'd0), .io_we(1'b0), .io_dout(),
	.MA(MA), .MD(MD), .MWR_N(MWR_N), .MRD_N(MRD_N)
);

endmodule
