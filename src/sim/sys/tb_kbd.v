`timescale 1ns / 1ps

// snes_kbd: each key of the table alone in each of the 6 places of the report gives its bit of
// its pad and nothing else; a key outside the table nothing; 6 keys at once all their bits.

module tb_kbd;

reg clk = 1'b0;
always #5 clk = ~clk;

reg [7:0] d [0:5];
wire [12:0] kb_l, kb_r;
snes_kbd dut(
	.clk(clk),
	.kb_dat0(d[0]), .kb_dat1(d[1]), .kb_dat2(d[2]), .kb_dat3(d[3]), .kb_dat4(d[4]), .kb_dat5(d[5]),
	.kb_l(kb_l), .kb_r(kb_r)
);

// usage code, pad (0 / 1), bit
reg [7:0] code [0:23];
reg pad [0:23];
reg [3:0] bit_n [0:23];
integer n = 0;
task add;
	input [7:0] c; input p; input [3:0] b;
	begin code[n] = c; pad[n] = p; bit_n[n] = b; n = n + 1; end
endtask

integer i, j, errors = 0;
reg [25:0] want;
initial begin
	add(8'h52, 0, 1); add(8'h51, 0, 2); add(8'h50, 0, 3); add(8'h4F, 0, 4);
	add(8'h28, 0, 5); add(8'h1D, 0, 6); add(8'h1B, 0, 7); add(8'h14, 0, 8);
	add(8'h04, 0, 9); add(8'h16, 0, 10); add(8'h1A, 0, 11); add(8'h2C, 0, 12);
	add(8'h0C, 1, 1); add(8'h0E, 1, 2); add(8'h0D, 1, 3); add(8'h0F, 1, 4);
	add(8'h10, 1, 5); add(8'h12, 1, 6); add(8'h13, 1, 7); add(8'h25, 1, 8);
	add(8'h26, 1, 9); add(8'h27, 1, 10); add(8'h2D, 1, 11); add(8'h11, 1, 12);
	for (j = 0; j < 6; j = j + 1) d[j] = 8'h00;
	for (i = 0; i < n; i = i + 1)
		for (j = 0; j < 6; j = j + 1) begin
			d[j] = code[i];
			@(posedge clk); @(posedge clk); #1;
			want = 26'd0;
			want[pad[i] * 13 + bit_n[i]] = 1'b1;
			if ({kb_r, kb_l} !== want) begin
				errors = errors + 1;
				$display("key %h at %0d: %b %b", code[i], j, kb_r, kb_l);
			end
			d[j] = 8'h00;
		end
	// outside the table
	d[0] = 8'h05; d[3] = 8'h39;
	@(posedge clk); @(posedge clk); #1;
	if ({kb_r, kb_l} !== 26'd0) begin errors = errors + 1; $display("unknown keys: %b %b", kb_r, kb_l); end
	// six at once
	d[0] = 8'h52; d[1] = 8'h1D; d[2] = 8'h28; d[3] = 8'h0F; d[4] = 8'h13; d[5] = 8'h11;
	@(posedge clk); @(posedge clk); #1;
	if (kb_l !== 13'b0000001100010 || kb_r !== 13'b1000010010000) begin
		errors = errors + 1; $display("six keys: %b %b", kb_r, kb_l);
	end
	$display("tb_kbd: %0d keys", n);
	$display("tb_kbd: %0d errors", errors);
	$finish;
end

endmodule
