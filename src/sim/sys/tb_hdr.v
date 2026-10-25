`timescale 1ns / 1ps

// snes_hdr on images built in a memory model of the rom port (answers a few clk after a toggle,
// as snes_sdram): LoROM, HiROM, ExHiROM headers, with and without a 512-byte copier header, a
// LoROM image that has random data at the HiROM place, a forced mapping (sel), an image too
// short for some places. Each case checks lhrom, hdr_off and the fields.

module tb_hdr;

reg clk = 1'b0;
always #23.27 clk = ~clk;

reg start = 1'b0;
reg [23:0] size = 24'd0;
reg [1:0] sel = 2'd0;
wire busy;
wire rom_req;
reg rom_ack = 1'b0;
wire [23:1] rom_addr;
reg [15:0] rom_dout = 16'd0;
wire [1:0] lhrom;
wire hdr_off;
wire [7:0] map, rtype, region, company;
wire [3:0] rom_size, ram_size;

snes_hdr dut(
	.clk(clk), .start(start), .size(size), .sel(sel), .busy(busy),
	.rom_req(rom_req), .rom_ack(rom_ack), .rom_addr(rom_addr), .rom_dout(rom_dout),
	.lhrom(lhrom), .hdr_off(hdr_off), .map(map), .rtype(rtype), .rom_size(rom_size),
	.ram_size(ram_size), .region(region), .company(company)
);

// the image: 8 MB of bytes, 0 outside the headers unless filled
reg [7:0] img [0:(1<<23)-1];
integer i;

// the rom port: the word of rom_addr some clk after a toggle
reg req_d = 1'b0;
integer wait_n = 0;
always @(posedge clk) begin
	req_d <= rom_req;
	if (rom_req != req_d) wait_n = 3 + ($random & 3);
	else if (wait_n > 0) begin
		wait_n = wait_n - 1;
		if (wait_n == 0) begin
			rom_dout <= {img[{rom_addr, 1'b1}], img[{rom_addr, 1'b0}]};
			rom_ack <= rom_req;
		end
	end
end

// a header at file offset a: map mode, type, rom size, ram size, region, company, a good or bad checksum,
// reset vector
task put_hdr;
	input [23:0] a;
	input [7:0] m, t, rs, ras, reg_, comp;
	input good;
	input [15:0] rst;
	reg [15:0] chk;
	begin
		chk = 16'h1234;
		img[a + 8'h15] = m;
		img[a + 8'h16] = t;
		img[a + 8'h17] = rs;
		img[a + 8'h18] = ras;
		img[a + 8'h19] = reg_;
		img[a + 8'h1A] = comp;
		img[a + 8'h1C] = good ? ~chk[7:0] : 8'h00;
		img[a + 8'h1D] = good ? ~chk[15:8] : 8'h00;
		img[a + 8'h1E] = chk[7:0];
		img[a + 8'h1F] = chk[15:8];
		img[a + 8'h3C] = rst[7:0];
		img[a + 8'h3D] = rst[15:8];
	end
endtask

task clear;
	begin
		for (i = 0; i < (1 << 23); i = i + 1) img[i] = 8'h00;
	end
endtask

integer errors = 0;
integer cases = 0;
task run;
	input [23:0] sz;
	input [1:0] s;
	input [1:0] exp_lh;
	input exp_off;
	input [7:0] exp_map;
	input [3:0] exp_ram;
	begin
		size = sz;
		sel = s;
		@(posedge clk); start <= 1'b1;
		@(posedge clk); start <= 1'b0;
		@(posedge clk);
		while (busy) @(posedge clk);
		cases = cases + 1;
		if (lhrom !== exp_lh || hdr_off !== exp_off || map !== exp_map || ram_size !== exp_ram) begin
			errors = errors + 1;
			$display("case %0d: lhrom %0d off %0d map %h ram %h, expected %0d %0d %h %h",
				cases, lhrom, hdr_off, map, ram_size, exp_lh, exp_off, exp_map, exp_ram);
		end
	end
endtask

initial begin
	// 1: LoROM 1 MB (Super Mario World style), no copier header
	clear;
	put_hdr(24'h007FC0, 8'h20, 8'h02, 8'h0A, 8'h01, 8'h01, 8'h01, 1'b1, 16'h8000);
	run(24'h100000, 2'd0, 2'd0, 1'b0, 8'h20, 4'h1);
	// 2: the same with a copier header (everything 512 bytes later)
	clear;
	put_hdr(24'h007FC0 + 24'h200, 8'h20, 8'h02, 8'h0A, 8'h01, 8'h01, 8'h01, 1'b1, 16'h8000);
	run(24'h100200, 2'd0, 2'd0, 1'b1, 8'h20, 4'h1);
	// 3: HiROM 4 MB, FastROM (31), with junk at the LoROM place
	clear;
	for (i = 24'h7FC0; i < 24'h8000; i = i + 1) img[i] = $random;
	put_hdr(24'h00FFC0, 8'h31, 8'h02, 8'h0C, 8'h03, 8'h00, 8'h33, 1'b1, 16'hFF00);
	run(24'h400000, 2'd0, 2'd1, 1'b0, 8'h31, 4'h3);
	// 4: ExHiROM 6 MB (35)
	clear;
	put_hdr(24'h40FFC0, 8'h35, 8'h02, 8'h0D, 8'h03, 8'h00, 8'h33, 1'b1, 16'h8100);
	run(24'h600000, 2'd0, 2'd2, 1'b0, 8'h35, 4'h3);
	// 5: the same image too short for ExHiROM: only the empty places score (RAM size and region 0)
	run(24'h300000, 2'd0, 2'd0, 1'b0, 8'h00, 4'h0);
	// 6: LoROM without a valid checksum (a hack), the HiROM place random: map mode and vector decide
	clear;
	for (i = 24'hFFC0; i < 24'h10000; i = i + 1) img[i] = $random;
	put_hdr(24'h007FC0, 8'h20, 8'h00, 8'h09, 8'h00, 8'h01, 8'h01, 1'b0, 16'h8000);
	run(24'h080000, 2'd0, 2'd0, 1'b0, 8'h20, 4'h0);
	// 7: forced HiROM on the LoROM image of case 1: the HiROM place (zeros) is taken
	clear;
	put_hdr(24'h007FC0, 8'h20, 8'h02, 8'h0A, 8'h01, 8'h01, 8'h01, 1'b1, 16'h8000);
	run(24'h100000, 2'd2, 2'd1, 1'b0, 8'h00, 4'h0);
	// 8: forced LoROM on it again
	run(24'h100000, 2'd1, 2'd0, 1'b0, 8'h20, 4'h1);
	// 9: the checksum decides: the LoROM place has a fitting map mode and a bad checksum (score 9),
	// the HiROM place a map mode of LoROM and a good checksum (13)
	clear;
	put_hdr(24'h007FC0, 8'h20, 8'h00, 8'h0A, 8'h00, 8'h01, 8'h01, 1'b0, 16'h8000);
	put_hdr(24'h00FFC0, 8'h20, 8'h00, 8'h0A, 8'h00, 8'h01, 8'h01, 1'b1, 16'h8000);
	run(24'h100000, 2'd0, 2'd1, 1'b0, 8'h20, 4'h0);
	$display("tb_hdr: %0d cases", cases);
	$display("tb_hdr: %0d errors", errors);
	$finish;
end

endmodule
