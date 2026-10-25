`timescale 1ns / 1ps
`default_nettype wire

/*
 snes_sram.v

 The SRAM of the board (2 x 2M x 8, one 16-bit word per address MA, async, 10 ns) as the VRAM,
 ARAM and BSRAM of the SNES, and a port for the loaders (SPC file, backup RAM).

 Clocks: clk (clk_mem) is 4 x clk_sys from the same PLL, phase 0; every edge of clk_sys is an
 edge of clk. ph is the phase of clk: 0 at the clk edge that is a rising clk_sys edge.

 Ports (as the ports of sdram_cl3 of the MiST SNES core): a request is a toggle of *_req (a
 register of clk_sys, of either edge) together with its address, write data and we, which stay
 until the next toggle. A port is open from a toggle until an access takes its address (the
 address of the last toggle); a toggle during the access opens it again. The answer sets *_ack
 to the value of *_req at the start of the access. *_ack and the read
 data *_dout change at a clk edge with ph = 0 only, so the logic of clk_sys that takes them has
 a whole clk_sys period (TS_SRAM_DOUT of the ucf). vram1 / vram2 (the low / high byte of a VRAM word) that ask for the
 same word with the same we are served as one 16-bit access.

 An access is three clk (34.9 ns at 85.9 MHz, as the SRAM controller of tsconf): the address and
 /OE (read) or the data (write) leave the IOB registers at its first edge; a read takes the data
 into the IOB registers at the edge three clk later (the first edge of the next access: 12 ns
 out + 10 ns tAA + 12 ns in fit, TS_SRAM_* of the ucf); a write has /WE low for its second clk
 only (11.6 ns, tPWE 8 ns), so the address and data are stable a clk before and after /WE. At most 1.33 accesses per clk_sys; the SNES
 needs about 1 at the most (VRAM 2, ARAM 1, BSRAM < 1 per dot of 4 clk_sys).

 Map of the SRAM (word addresses, MA):
   000000-007FFF  VRAM, word n = VRAM2:VRAM1 of address n
   008000-00FFFF  ARAM, address bit 0 = byte (0 low, 1 high)
   080000-0FFFFF  BSRAM, up to 1 MB, as the ARAM
 ARAM and BSRAM read whole words (the SNES side picks the byte with the address bit 0 of the
 moment, as the MiST core does: a read of the other byte of the word asks for nothing) and write
 the byte of address bit 0.
   the io port addresses words directly (22-bit byte address, bit 0 = byte, word = 16 bits)

 Priority: VRAM, ARAM, BSRAM, io.
*/

module snes_sram (
	input wire clk,
	input wire [1:0] ph,

	input wire vram1_req,
	output reg vram1_ack = 1'b0,
	input wire [14:0] vram1_addr,
	input wire [7:0] vram1_din,
	input wire vram1_we,
	output reg [7:0] vram1_dout = 8'd0,

	input wire vram2_req,
	output reg vram2_ack = 1'b0,
	input wire [14:0] vram2_addr,
	input wire [7:0] vram2_din,
	input wire vram2_we,
	output reg [7:0] vram2_dout = 8'd0,

	input wire aram_req,
	output reg aram_ack = 1'b0,
	input wire [15:0] aram_addr,
	input wire [7:0] aram_din,
	input wire aram_we,
	output reg [15:0] aram_dout = 16'd0,  // the word of aram_addr[15:1]

	input wire bsram_req,
	output reg bsram_ack = 1'b0,
	input wire [19:0] bsram_addr,
	input wire [7:0] bsram_din,
	input wire bsram_we,
	output reg [15:0] bsram_dout = 16'd0, // the word of bsram_addr[19:1]

	input wire io_req,
	output reg io_ack = 1'b0,
	input wire [21:0] io_addr,       // byte address
	input wire io_word,              // 1: a 16-bit access (io_addr[0] = 0)
	input wire [15:0] io_din,        // a byte access writes io_din[7:0]
	input wire io_we,
	output reg [15:0] io_dout = 16'd0,

	output reg [20:0] MA = 21'd0,
	inout wire [15:0] MD,
	output reg [1:0] MWR_N = 2'b11,
	output reg [1:0] MRD_N = 2'b11
);

localparam P_NONE = 3'd0, P_VRAM = 3'd1, P_VRAM1 = 3'd2, P_VRAM2 = 3'd3, P_ARAM = 3'd4,
	P_BSRAM = 3'd5, P_IO = 3'd6;

// the requests of clk_sys: a port is open from a change of its req (seen at the clk edge after
// it) until an access takes its address; a change during the access opens it again
reg vram1_req_d = 1'b0, vram2_req_d = 1'b0, aram_req_d = 1'b0, bsram_req_d = 1'b0, io_req_d = 1'b0;
reg vram1_pend = 1'b0, vram2_pend = 1'b0, aram_pend = 1'b0, bsram_pend = 1'b0, io_pend = 1'b0;
wire vram1_open = vram1_pend || vram1_req != vram1_req_d;
wire vram2_open = vram2_pend || vram2_req != vram2_req_d;
wire aram_open = aram_pend || aram_req != aram_req_d;
wire bsram_open = bsram_pend || bsram_req != bsram_req_d;
wire io_open = io_pend || io_req != io_req_d;

// a port being served is not open for the arbiter until its answer
reg [6:1] busy = 6'd0;   // per port P_*
reg [6:1] done = 6'd0;   // answers waiting for ph 0
reg v1_tag = 1'b0, v2_tag = 1'b0, a_tag = 1'b0, b_tag = 1'b0, i_tag = 1'b0; // *_req at the start

reg [1:0] cyc = 2'd0;    // clk of the current access, 0 = idle
reg [2:0] port = P_NONE;
reg [1:0] bsel = 2'b00;  // the bytes of the access (1 = selected)
reg we = 1'b0;

reg [15:0] md_out = 16'd0;
reg md_oe = 1'b0;
assign MD = md_oe ? md_out : 16'bz;

// read data of the IOB registers, taken at the edge three clk after the start of a read
reg [15:0] md_in = 16'd0;
reg take = 1'b0;           // md_in has the data of take_port at this edge
reg [2:0] take_port = P_NONE;
reg [1:0] take_bsel = 2'b00;

// results waiting for ph 0
reg [7:0] r_vram1 = 8'd0, r_vram2 = 8'd0;
reg [15:0] r_aram = 16'd0, r_bsram = 16'd0;
reg [15:0] r_io = 16'd0;

// the next access (combinational arbiter)
reg [2:0] nport;
reg [20:0] naddr;
reg [15:0] ndata;
reg [1:0] nbsel;
reg nwe;
always @(*) begin
	nport = P_NONE;
	naddr = 21'd0;
	ndata = 16'd0;
	nbsel = 2'b00;
	nwe = 1'b0;
	if (vram1_open && !busy[P_VRAM1] && vram2_open && !busy[P_VRAM2] &&
	    vram1_addr == vram2_addr && vram1_we == vram2_we) begin
		nport = P_VRAM;
		naddr = {6'd0, vram1_addr};
		ndata = {vram2_din, vram1_din};
		nbsel = 2'b11;
		nwe = vram1_we;
	end else if (vram1_open && !busy[P_VRAM1]) begin
		nport = P_VRAM1;
		naddr = {6'd0, vram1_addr};
		ndata = {vram1_din, vram1_din};
		nbsel = 2'b01;
		nwe = vram1_we;
	end else if (vram2_open && !busy[P_VRAM2]) begin
		nport = P_VRAM2;
		naddr = {6'd0, vram2_addr};
		ndata = {vram2_din, vram2_din};
		nbsel = 2'b10;
		nwe = vram2_we;
	end else if (aram_open && !busy[P_ARAM]) begin
		nport = P_ARAM;
		naddr = {6'd1, aram_addr[15:1]};
		ndata = {aram_din, aram_din};
		nbsel = (aram_we && aram_addr[0]) ? 2'b10 : aram_we ? 2'b01 : 2'b11;
		nwe = aram_we;
	end else if (bsram_open && !busy[P_BSRAM]) begin
		nport = P_BSRAM;
		naddr = {2'b01, bsram_addr[19:1]};
		ndata = {bsram_din, bsram_din};
		nbsel = (bsram_we && bsram_addr[0]) ? 2'b10 : bsram_we ? 2'b01 : 2'b11;
		nwe = bsram_we;
	end else if (io_open && !busy[P_IO]) begin
		nport = P_IO;
		naddr = io_addr[21:1];
		ndata = io_word ? io_din : {io_din[7:0], io_din[7:0]};
		nbsel = io_word ? 2'b11 : (io_addr[0] ? 2'b10 : 2'b01);
		nwe = io_we;
	end
end

// the bits of the ports of an access: bit n is the port P_* = n (bit 1 is not used)
function [6:1] ports;
	input [2:0] p;
	begin
		case (p)
			P_VRAM: ports = 6'b000110;
			P_VRAM1: ports = 6'b000010;
			P_VRAM2: ports = 6'b000100;
			P_ARAM: ports = 6'b001000;
			P_BSRAM: ports = 6'b010000;
			P_IO: ports = 6'b100000;
			default: ports = 6'b000000;
		endcase
	end
endfunction

// the byte of a result: an 8-bit port gets the byte it selected
function [7:0] pick;
	input [15:0] d;
	input [1:0] sel;
	begin
		pick = sel[1] ? d[15:8] : d[7:0];
	end
endfunction

wire start = (cyc == 2'd0 || cyc == 2'd3) && nport != P_NONE;
wire [6:1] start_ports = start ? ports(nport) : 6'd0;
// the ports whose access ends at this edge: a write at its last clk, a read when its data are taken
wire [6:1] end_ports = ((cyc == 2'd3 && we) ? ports(port) : 6'd0) | (take ? ports(take_port) : 6'd0);

always @(posedge clk) begin
	{vram1_req_d, vram2_req_d, aram_req_d, bsram_req_d, io_req_d} <= {vram1_req, vram2_req, aram_req, bsram_req, io_req};
	vram1_pend <= vram1_open && !start_ports[P_VRAM1];
	vram2_pend <= vram2_open && !start_ports[P_VRAM2];
	aram_pend <= aram_open && !start_ports[P_ARAM];
	bsram_pend <= bsram_open && !start_ports[P_BSRAM];
	io_pend <= io_open && !start_ports[P_IO];

	md_in <= MD;
	take <= 1'b0;

	// the access
	if (cyc == 2'd0 || cyc == 2'd3) begin
		if (cyc == 2'd3 && !we) begin
			take <= 1'b1;
			take_port <= port;
			take_bsel <= bsel;
		end
		MWR_N <= 2'b11;
		if (start) begin
			cyc <= 2'd1;
			port <= nport;
			bsel <= nbsel;
			we <= nwe;
			MA <= naddr;
			md_out <= ndata;
			md_oe <= nwe;
			MRD_N <= nwe ? 2'b11 : ~nbsel;
		end else begin
			cyc <= 2'd0;
			port <= P_NONE;
			we <= 1'b0;
			md_oe <= 1'b0;
			MRD_N <= 2'b11;
		end
	end else begin
		cyc <= cyc + 2'd1;
		// /WE low for the second clk of a write only: the address and data are stable a clk
		// before and after it
		if (we && cyc == 2'd1) MWR_N <= ~bsel;
		else MWR_N <= 2'b11;
	end

	if (start_ports[P_VRAM1]) v1_tag <= vram1_req;
	if (start_ports[P_VRAM2]) v2_tag <= vram2_req;
	if (start_ports[P_ARAM]) a_tag <= aram_req;
	if (start_ports[P_BSRAM]) b_tag <= bsram_req;
	if (start_ports[P_IO]) i_tag <= io_req;

	// the read data of the IOB registers
	if (take) begin
		case (take_port)
			P_VRAM: begin r_vram1 <= md_in[7:0]; r_vram2 <= md_in[15:8]; end
			P_VRAM1: r_vram1 <= md_in[7:0];
			P_VRAM2: r_vram2 <= md_in[15:8];
			P_ARAM: r_aram <= md_in;
			P_BSRAM: r_bsram <= md_in;
			P_IO: r_io <= (take_bsel == 2'b11) ? md_in : {8'd0, pick(md_in, take_bsel)};
			default: ;
		endcase
	end

	// the answers, at ph 0 only; an access that ends at this edge answers at the next ph 0
	if (ph == 2'd0) begin
		if (done[P_VRAM1]) begin vram1_dout <= r_vram1; vram1_ack <= v1_tag; end
		if (done[P_VRAM2]) begin vram2_dout <= r_vram2; vram2_ack <= v2_tag; end
		if (done[P_ARAM]) begin aram_dout <= r_aram; aram_ack <= a_tag; end
		if (done[P_BSRAM]) begin bsram_dout <= r_bsram; bsram_ack <= b_tag; end
		if (done[P_IO]) begin io_dout <= r_io; io_ack <= i_tag; end
		busy <= (busy & ~done) | start_ports;
		done <= end_ports;
	end else begin
		busy <= busy | start_ports;
		done <= done | end_ports;
	end
end

endmodule
