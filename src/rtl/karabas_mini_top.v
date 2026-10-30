`timescale 1ns / 1ps
`default_nettype wire

/*-------------------------------------------------------------------------------------------------------------------
--
--
-- #       #######                                                 #
-- #                                                               #
-- #                                                               #
-- ############### ############### ############### ############### ############### ############### ###############
-- #             #               # #                             # #             #               # #
-- #             # ############### #               ############### #             # ############### ###############
-- #             # #             # #               #             # #             # #             #               #
-- #             # ############### #               ############### ############### ############### ###############
--
--         ####### ####### ####### #######                                         ############### ###############
--                                                                                 #               #             #
--                                                                                 #   ########### #             #
--                                                                                 #             # #             #
-- https://github.com/andykarpov/karabas-go                                        ############### ###############
--
-- FPGA SNES core for Karabas-Go Mini
--
-- @author Andy Karpov <andy.karpov@gmail.com>
-- Ukraine, 2026
------------------------------------------------------------------------------------------------------------------*/

module karabas_mini_top (
   //---------------------------
   input wire CLK_50MHZ,

	//---------------------------
	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,
	
   //---------------------------
   output wire [20:0] MA,
   inout wire [15:0] MD,
   output wire [1:0] MWR_N,
   output wire [1:0] MRD_N,

   //---------------------------
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

   //---------------------------
   output wire SD_CS_N,
   output wire SD_CLK,
   output wire SD_DI,
   input wire SD_DO,
	input wire SD_DET_N,

   //---------------------------
   input wire [7:0] VGA_R,
   input wire [7:0] VGA_G,
   input wire [7:0] VGA_B,
   input wire VGA_HS,
   input wire VGA_VS,
	
   output wire [3:0] TMDS_P,
   output wire [3:0] TMDS_N,	
	
	//---------------------------
	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	input wire FT_AUDIO,
	input wire FT_DE,
	input wire FT_DISP,
	output wire FT_RESET,

	//---------------------------
	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,
	
   //---------------------------	
	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire AUDIO_L,
	output wire AUDIO_R,
	
	//---------------------------
	output wire ADC_CLK,
   inout wire ADC_BCK,
	inout wire ADC_LRCK,
   input wire ADC_DOUT,
	
	//---------------------------
	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,	
	inout wire [4:0] MCU_IO, // [0] burst cs_n, [1] burst ready, [2] sd2 cs_n, [3] ft cs_n, [4] ft clk (mod): input only
	
	//---------------------------
	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,
	
	//---------------------------
	output wire FLASH_CS_N,
	input wire  FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N	
);

// unused signals

assign WA = 3'b000;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bz;

assign TAPE_OUT = 1'b0;
assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FT_RESET = 1'b1;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

//---------- clocks ------------

// 50 MHz * 12 = 600 MHz VCO: clk_sys 600 / 28 = 21.429 MHz (the SNES master clock, NTSC 21.477
// - 0.22 %: 59.97 Hz frames; the PFD of the PLL needs 19 MHz or more, so DIVCLK_DIVIDE is 1 or 2
// and this is the closest 4:1 pair), clk_mem 600 / 7 = 85.71 MHz = 4 x clk_sys, phase 0;
// 600 / 22 = 27.27 MHz: clk_pix of PAL (below)
wire [5:0] pll_clk;
wire locked;
kg_pll #(
	.CLKIN_PERIOD(20.0),
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(12),
	.CLKOUT0_DIVIDE(28),
	.CLKOUT1_DIVIDE(7),
	.CLKOUT2_DIVIDE(22),
	.BUFG_MASK(6'b000011)
) pll(
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(locked)
);
wire clk_sys = pll_clk[0];
wire clk_mem = pll_clk[1];
wire areset = ~locked;

// the pixel clock of the 640 x 480 output: a second PLL on clk_sys, VCO 21.429 x 40 = 857.1 MHz,
// clk_pix 857.1 / 34 = 25.21 MHz = clk_sys x 40 / 34 (snes_video: a SNES frame is 420432 clk_pix,
// an output frame 420000, locked through 256 lines). DVI needs 25 MHz or more: the first build had
// clk_sys (21.4 MHz) as pixel clock. The 5 x clock pair of the serialisers: a DCM on clk_pix, as in
// the NES core (the PLL cannot have both: x 47 / 40 and its x 5 need a VCO of 1007 MHz, over 1000).
wire [5:0] pix_clk;
wire locked_pix;
kg_pll #(
	.CLKIN_PERIOD(46.667),
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(40),
	.CLKOUT2_DIVIDE(34),
	.IBUFG(0),
	.BUFG_MASK(6'b000000)
) pll_pix(
	.clk_in(clk_sys),
	.rst(areset),
	.clk_out(pix_clk),
	.locked(locked_pix)
);

// PAL: CEA 576p on 600 / 22 = 27.27 MHz = clk_sys x 28 / 22 (a SNES PAL frame is 541632 clk_pix, an
// output frame 864 x 625 = 540000), from pll; the 800 x 625 of 25.21 MHz before was no standard
// mode and a monitor did not show it. A BUFGMUX takes it while the SNES is PAL (vid_pal of the
// core: PAL chosen in the OSD; auto is NTSC, constant while a game runs).
wire vid_pal;
wire dvi_only;                  // kg_mcu (the firmware setting): no HDMI islands (snes_hdmi)
wire clk_pix;
BUFGMUX #(.CLK_SEL_TYPE("SYNC")) clk_pix_mux(.I0(pix_clk[2]), .I1(pll_clk[2]), .S(vid_pal), .O(clk_pix));

// the DCM loses its lock when clk_pix changes: a reset of 256 clk_sys after a change of the mode
reg vid_pal_d = 1'b0;
reg [7:0] x5_rst_cnt = 8'd0;
always @(posedge clk_sys) begin
	vid_pal_d <= vid_pal;
	if (vid_pal != vid_pal_d) x5_rst_cnt <= 8'd255;
	else if (x5_rst_cnt != 8'd0) x5_rst_cnt <= x5_rst_cnt - 8'd1;
end
wire x5_rst = x5_rst_cnt != 8'd0;

wire clk_hdmi, clk_hdmi_n, locked_x5;
kg_dcm #(
	.CLKIN_PERIOD(39.667),
	.CLKFX_MULTIPLY(5),
	.CLKFX_DIVIDE(1)
) pllx5(
	.clk_in(clk_pix),
	.rst(~locked_pix | x5_rst),
	.clk_fx(clk_hdmi),
	.clk_fx180(clk_hdmi_n),
	.clk_0(),
	.locked(locked_x5)
);
wire locked_hdmi = locked_pix & locked_x5;

//---------- MCU ------------

wire [7:0] hid_kb_status, hid_kb_dat0, hid_kb_dat1, hid_kb_dat2, hid_kb_dat3, hid_kb_dat4, hid_kb_dat5;
wire [12:0] joy_l, joy_r;
wire fileloader_active;
wire [31:0] fileloader_addr;
wire [7:0] fileloader_data;
wire fileloader_wr;
wire [15:0] softsw_command, osd_command;
wire mcu_busy;

// burst transfers from the mcu (karabas-go-firmware docs/burst_protocol.md)
wire mcu_burst_ready;
assign MCU_IO[1] = mcu_burst_ready;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[4:2] = 3'bzzz;

// MCU_SCK is not on a global clock pin here: bursts at the default speed
kg_mcu #(
	.BURST_MAX_MHZ(0),
	.CS_FILTER(3),
	.ENABLE_RTC(0),
	.ENABLE_UART(0),
	.ENABLE_MATRIX(0),
	.ENABLE_DEBUG(0),
	.ENABLE_IMG(0),
	.ENABLE_FILE(1),
	.FILE_CMDS(1),     // FILEBANK / FILEDATA / FILELOADER: the ROM image
	.FILE_WR_EACH(1),  // every byte (a new load starts at 0 again)
	.FILE_TO_ROM(0),
	.ENABLE_FT(1),
	.ENABLE_SD2(1)
) mcu(
	.CLK(clk_sys),
	.N_RESET(~areset),

	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SCK(MCU_SCK),
	.MCU_SS(MCU_CS_N),

	.MCU_SPI_FT_SS(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),
	.MCU_BURST_CS_N(MCU_IO[0]),
	.MCU_BURST_READY(mcu_burst_ready),

	.KB_STATUS(hid_kb_status),
	.KB_DAT0(hid_kb_dat0),
	.KB_DAT1(hid_kb_dat1),
	.KB_DAT2(hid_kb_dat2),
	.KB_DAT3(hid_kb_dat3),
	.KB_DAT4(hid_kb_dat4),
	.KB_DAT5(hid_kb_dat5),

	.JOY_L(joy_l),
	.JOY_R(joy_r),

	.ROMLOADER_ACTIVE(),
	.ROMLOAD_ADDR(),
	.ROMLOAD_DATA(),
	.ROMLOAD_WR(),

	.FILELOAD_RESET(),
	.FILELOAD_ACTIVE(fileloader_active),
	.FILELOAD_SIZE(),
	.FILELOAD_ADDR(fileloader_addr),
	.FILELOAD_DATA(fileloader_data),
	.FILELOAD_WR(fileloader_wr),

	.SOFTSW_COMMAND(softsw_command),
	.OSD_COMMAND(osd_command),

	.BUSY(mcu_busy),

	.FT_VGA_ON(),

	.FT_CS_N(FT_SPI_CS_N),
	.FT_MOSI(FT_SPI_MOSI),
	.FT_MISO(FT_SPI_MISO),
	.FT_SCK(FT_SPI_SCK),

	.SD2_CS_N(SD_CS_N),
	.SD2_MOSI(SD_DI),
	.SD2_MISO(SD_DO),
	.SD2_SCK(SD_CLK),

	.HWID(),
	.DVI_ONLY(dvi_only),

	.DEBUG_ADDR(16'h00),
	.DEBUG_DATA(),

	// not used by this core
	.RTC_A(8'h00),
	.RTC_DI(8'h00),
	.RTC_CS(1'b0),
	.RTC_WR_N(1'b1),
	.UART_TX_DATA(8'h00),
	.UART_TX_WR(1'b0),
	.UART_TX_MODE(1'b0),
	.UART_DLM(8'h00),
	.UART_DLL(8'h00),
	.UART_DLM_WR(1'b0),
	.UART_DLL_WR(1'b0),
	.MATRIX_CMD(24'h000000),
	.MATRIX_CMD_WR(1'b0),
	.IMG_Q_WR(1'b0),
	.IMG_Q_DI(24'h000000),
	.ESP_UART_RX_DATA(8'h00),
	.ESP_UART_RX_WR(1'b0),
	.FLASHBOOT_START(1'b0),
	.FLASHBOOT_COREID(5'd0)
);

//---------- SNES: soft switches, joysticks, the SNES, 31 kHz video, OSD ------------

wire [23:0] osd_rgb;
wire hd_hs, hd_vs, hd_de;
wire [15:0] audio_l, audio_r;
wire audio_lrck;

snes_core #(.USE_DSPN(1)) core(
	.clk_sys(clk_sys),
	.clk_mem(clk_mem),
	.clk_pix(clk_pix),
	.areset(areset),
	.softsw_command(softsw_command),
	.osd_command(osd_command),
	.mcu_busy(mcu_busy),
	.joy_l(joy_l),
	.joy_r(joy_r),
	.kb_dat0(hid_kb_dat0),
	.kb_dat1(hid_kb_dat1),
	.kb_dat2(hid_kb_dat2),
	.kb_dat3(hid_kb_dat3),
	.kb_dat4(hid_kb_dat4),
	.kb_dat5(hid_kb_dat5),
	.load_active(fileloader_active),
	.load_addr(fileloader_addr),
	.load_data(fileloader_data),
	.load_wr(fileloader_wr),
	.rgb(osd_rgb),
	.hs(hd_hs),
	.vs(hd_vs),
	.de(hd_de),
	.pal(vid_pal),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.audio_lrck(audio_lrck),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N),
	.MRD_N(MRD_N),
	.SDR_CLK(SDR_CLK),
	.SDR_BA(SDR_BA),
	.SDR_A(SDR_A),
	.SDR_DQM(SDR_DQM),
	.SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N),
	.SDR_WE_N(SDR_WE_N),
	.SDR_DQ(SDR_DQ)
);

//---------- HDMI ------------

// HDMI with the sound of the SNES and the AVI InfoFrame (snes_hdmi: its own small encoder; hdmi_tx of zhdmi
// is 2240 LUTs and did not fit); plain DVI when the firmware says dvi_only. 640 x 480 and 576p: negative
// syncs.
wire [9:0] enc_r, enc_g, enc_b;
snes_hdmi hdmi(
	.clk_pix(clk_pix),
	.pal(vid_pal),
	.dvi_only(dvi_only),
	.rgb(osd_rgb),
	.hs(hd_hs),
	.vs(hd_vs),
	.de(hd_de),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.lrck(audio_lrck),
	.tmds_r(enc_r),
	.tmds_g(enc_g),
	.tmds_b(enc_b)
);

tmds_serializer ser_b(.clk(clk_pix), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(enc_b), .tx_d_n(TMDS_N[0]), .tx_d_p(TMDS_P[0]));
tmds_serializer ser_g(.clk(clk_pix), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(enc_g), .tx_d_n(TMDS_N[1]), .tx_d_p(TMDS_P[1]));
tmds_serializer ser_r(.clk(clk_pix), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(enc_r), .tx_d_n(TMDS_N[2]), .tx_d_p(TMDS_P[2]));
tmds_serializer ser_c(.clk(clk_pix), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(10'b1111100000), .tx_d_n(TMDS_N[3]), .tx_d_p(TMDS_P[3]));

//---------- audio DAC ------------

// sigma-delta on AUDIO_L / AUDIO_R, the 16-bit signed samples as unsigned (as the NES core)
kg_sigma_delta_dac dac_l(
	.clk(clk_sys),
	.reset(areset),
	.din({2'b00, ~audio_l[15], audio_l[14:4], 2'b00}),
	.dout(AUDIO_L)
);

kg_sigma_delta_dac dac_r(
	.clk(clk_sys),
	.reset(areset),
	.din({2'b00, ~audio_r[15], audio_r[14:4], 2'b00}),
	.dout(AUDIO_R)
);

endmodule
