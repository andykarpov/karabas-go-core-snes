`timescale 1ns / 1ps

// A model of the MT48LC16M16A2 for tb_sdram.v: single reads and writes with auto precharge,
// CL 2, burst 1, the commands taken at the rising edge of clk. Read data are driven tAC after
// the edge CL clk after the READ and held tOH after the next edge. Checks: tRCD, tRC (ACTIVE to
// ACTIVE / REFRESH), tRFC, a READ / WRITE only to an open row, the init sequence (a mode
// register load before the first ACTIVE), the refresh rate (8192 in 64 ms). The memory holds
// the words written only (a read of another word gives X).

module sdram_model #(
	parameter real T_AC = 6.0,
	parameter real T_OH = 2.7,
	parameter real T_CLK = 11.64
) (
	input wire clk,
	input wire [1:0] ba,
	input wire [12:0] a,
	input wire [1:0] dqm,
	input wire ras_n,
	input wire cas_n,
	input wire we_n,
	inout wire [15:0] dq
);

reg [15:0] mem [0:(1<<24)-1];
reg [12:0] row [0:3];
reg open [0:3];
real t_act [0:3];
real t_last_act, t_rfs;
reg mode_set = 1'b0;
integer errors = 0;
integer refreshes = 0;
real t_first_rfs = -1.0;

reg [15:0] dout;
reg doe = 1'b0;
assign dq = doe ? dout : 16'bz;

// read pipeline: data of the READ CL edges ago
reg [15:0] rd_data [0:2];
reg rd_v [0:2];
integer i;
initial begin
	for (i = 0; i < 4; i = i + 1) begin open[i] = 1'b0; t_act[i] = -1000.0; end
	for (i = 0; i < 3; i = i + 1) rd_v[i] = 1'b0;
	t_last_act = -1000.0;
	t_rfs = -1000.0;
end

task err;
	input [8*64-1:0] msg;
	begin
		errors = errors + 1;
		if (errors < 20) $display("%t sdram_model: %0s", $time, msg);
	end
endtask

wire [2:0] cmd = {ras_n, cas_n, we_n};
always @(posedge clk) begin
	// the read pipeline: a READ of this edge drives its data tAC after the edge CL (2) later
	rd_v[2] = rd_v[1]; rd_data[2] = rd_data[1];
	rd_v[1] = rd_v[0]; rd_data[1] = rd_data[0];
	rd_v[0] = 1'b0;
	doe <= #(T_OH) 1'b0;
	if (rd_v[2]) begin
		dout <= #(T_AC) rd_data[2];
		doe <= #(T_AC) 1'b1;
	end

	case (cmd)
		3'b011: begin // ACTIVE
			if (!mode_set) err("ACTIVE before the mode register");
			if ($realtime - t_act[ba] < 66.0 - 0.01) err("tRC");
			if ($realtime - t_rfs < 66.0 - 0.01) err("tRFC");
			if (open[ba]) err("ACTIVE of an open bank");
			open[ba] = 1'b1;
			row[ba] = a;
			t_act[ba] = $realtime;
			t_last_act = $realtime;
		end
		3'b101, 3'b100: begin // READ, WRITE
			if (!open[ba]) err("READ / WRITE of a closed bank");
			if ($realtime - t_act[ba] < 20.0 - 0.01) err("tRCD");
			if (!a[10]) err("no auto precharge");
			if (cmd == 3'b100) begin
				if (!dqm[0]) mem[{ba, row[ba], a[8:0]}][7:0] = dq[7:0];
				if (!dqm[1]) mem[{ba, row[ba], a[8:0]}][15:8] = dq[15:8];
			end else begin
				rd_v[0] = 1'b1;
				rd_data[0] = mem[{ba, row[ba], a[8:0]}];
				if (dqm != 2'b00) err("READ with DQM");
			end
			open[ba] = 1'b0; // auto precharge (its timing is covered by tRC)
		end
		3'b001: begin // AUTO REFRESH
			for (i = 0; i < 4; i = i + 1) begin
				if (open[i]) err("REFRESH with an open bank");
				if ($realtime - t_act[i] < 66.0 - 0.01) err("tRC before REFRESH");
			end
			if ($realtime - t_rfs < 66.0 - 0.01) err("tRFC");
			t_rfs = $realtime;
			if (mode_set) begin
				if (t_first_rfs < 0.0) t_first_rfs = $realtime;
				refreshes = refreshes + 1;
			end
		end
		3'b000: mode_set = 1'b1; // LOAD MODE (CL 2 assumed)
		3'b010: for (i = 0; i < 4; i = i + 1) open[i] = 1'b0; // PRECHARGE
		default: ;
	endcase
end

// refresh rate: at least 8192 in 64 ms, i.e. one per 7.8125 us on average
task check_refresh;
	real span;
	begin
		span = $realtime - t_first_rfs;
		if (span > 20000.0 && refreshes < span / 7812.5) begin
			errors = errors + 1;
			$display("sdram_model: %0d refreshes in %0.0f ns", refreshes, span);
		end
	end
endtask

endmodule
