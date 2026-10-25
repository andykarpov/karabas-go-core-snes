`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_hdr.v

 Finds the SNES header of a loaded ROM image. The firmware of the Karabas does not parse it (the
 ARM of the MiST gives the mapping in ioctl_index, the RISC-V of snestang parses it), so after
 the load the core reads the six places a header can be from the SDRAM (through the rom port of
 snes_sdram, while the SNES is in reset) and takes the one with the best score:
   LoROM 007FC0, HiROM 00FFC0, ExHiROM 40FFC0, each at file offset 0 and 200 (a 512-byte copier
   header in front of the image, .smc).
 Score of a candidate (only those in_file the loaded file, and of the forced mapping if sel != 0):
   +8 the checksum (bytes 1E-1F) and its complement (1C-1D) give FFFF
   +4 the map mode (byte 15) fits the place: bits 7..5 = 001 and LoROM: bit 0 = 0, bit 2 = 0;
      HiROM: bit 0 = 1, bit 2 = 0; ExHiROM: bit 2 = 1 (25, 35)
   +2 the reset vector (byte 3C) is 8000 or above and not FFFF
   +1 each: ROM size (17) 08..0D, RAM size (18) 00..07, region (19) 00..14
 The first candidate wins a tie (LoROM before HiROM before ExHiROM, offset 0 before 200).
 Read words: bytes 14/15, 16/17, 18/19, 1A, 1C/1D, 1E/1F, 3C/3D of the candidate; the even byte
 of a word is its low byte (as the loader writes them).
*/

module snes_hdr (
	input wire clk,
	input wire start,            // one clk: the image is loaded
	input wire [23:0] size,      // bytes loaded (the highest file offset + 1)
	input wire [1:0] sel,        // 0 auto, 1 LoROM, 2 HiROM, 3 ExHiROM
	output reg busy = 1'b0,

	// rom port of snes_sdram (owned by this module while busy)
	output reg rom_req = 1'b0,
	input wire rom_ack,
	output reg [23:1] rom_addr = 23'd0,
	input wire [15:0] rom_dout,

	// the header found (zero when none scored)
	output reg [1:0] lhrom = 2'd0,   // 0 LoROM, 1 HiROM, 2 ExHiROM
	output reg hdr_off = 1'b0,       // the image starts at file offset 200
	output reg [7:0] map = 8'd0,
	output reg [7:0] rtype = 8'd0,
	output reg [3:0] rom_size = 4'd0,
	output reg [3:0] ram_size = 4'd0,
	output reg [7:0] region = 8'd0,
	output reg [7:0] company = 8'd0
);

reg [2:0] c = 3'd0;          // candidate: {mapping (0 Lo, 1 Hi, 2 ExHi), offset}
reg [2:0] k = 3'd0;          // word of the candidate
reg waiting = 1'b0;
reg [4:0] best = 5'd0;

reg [7:0] t_map = 8'd0, t_type = 8'd0, t_rsize = 8'd0, t_ramsize = 8'd0, t_region = 8'd0, t_comp = 8'd0;
reg [15:0] t_cpl = 16'd0, t_chk = 16'd0, t_rst = 16'd0;

wire [1:0] ty = c[2:1];
wire [23:0] base = (ty == 2'd0 ? 24'h007FC0 : ty == 2'd1 ? 24'h00FFC0 : 24'h40FFC0) + (c[0] ? 24'h000200 : 24'h000000);
wire in_file = base + 24'h40 <= size;
wire allowed = sel == 2'd0 || sel == ty + 2'd1;
reg [7:0] w_off;
always @(*)
	case (k)
		3'd0: w_off = 8'h14;
		3'd1: w_off = 8'h16;
		3'd2: w_off = 8'h18;
		3'd3: w_off = 8'h1A;
		3'd4: w_off = 8'h1C;
		3'd5: w_off = 8'h1E;
		default: w_off = 8'h3C;
	endcase

wire map_fits = t_map[7:5] == 3'b001 &&
	(ty == 2'd0 ? (!t_map[0] && !t_map[2]) : ty == 2'd1 ? (t_map[0] && !t_map[2]) : t_map[2]);
wire [4:0] score =
	(((t_cpl ^ t_chk) == 16'hFFFF) ? 5'd8 : 5'd0) +
	(map_fits ? 5'd4 : 5'd0) +
	((t_rst[15] && t_rst != 16'hFFFF) ? 5'd2 : 5'd0) +
	((t_rsize >= 8'h08 && t_rsize <= 8'h0D) ? 5'd1 : 5'd0) +
	((t_ramsize <= 8'h07) ? 5'd1 : 5'd0) +
	((t_region <= 8'h14) ? 5'd1 : 5'd0);

always @(posedge clk) begin
	if (start) begin
		busy <= 1'b1;
		c <= 3'd0;
		k <= 3'd0;
		waiting <= 1'b0;
		best <= 5'd0;
		lhrom <= 2'd0; hdr_off <= 1'b0; map <= 8'd0; rtype <= 8'd0; rom_size <= 4'd0;
		ram_size <= 4'd0; region <= 8'd0; company <= 8'd0;
	end else if (busy) begin
		if (c > 3'd5) begin
			busy <= 1'b0;
		end else if (!in_file || !allowed) begin
			c <= c + 3'd1;
			k <= 3'd0;
		end else if (!waiting) begin
			if (k == 3'd7) begin
				// the words are read: score the candidate
				if (score > best) begin
					best <= score;
					lhrom <= ty;
					hdr_off <= c[0];
					map <= t_map;
					rtype <= t_type;
					rom_size <= t_rsize[3:0];
					ram_size <= t_ramsize[3:0];
					region <= t_region;
					company <= t_comp;
				end
				c <= c + 3'd1;
				k <= 3'd0;
			end else begin
				rom_addr <= base[23:1] + {15'd0, w_off[7:1]};
				rom_req <= ~rom_req;
				waiting <= 1'b1;
			end
		end else if (rom_ack == rom_req) begin
			waiting <= 1'b0;
			k <= k + 3'd1;
			case (k)
				3'd0: t_map <= rom_dout[15:8];
				3'd1: begin t_type <= rom_dout[7:0]; t_rsize <= rom_dout[15:8]; end
				3'd2: begin t_ramsize <= rom_dout[7:0]; t_region <= rom_dout[15:8]; end
				3'd3: t_comp <= rom_dout[7:0];
				3'd4: t_cpl <= rom_dout;
				3'd5: t_chk <= rom_dout;
				default: t_rst <= rom_dout;
			endcase
		end
	end
end

endmodule
