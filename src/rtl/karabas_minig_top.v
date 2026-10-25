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
-- FPGA SNES core for Karabas-Go Mini G
--
-- @author Andy Karpov <andy.karpov@gmail.com>
-- Ukraine, 2026
------------------------------------------------------------------------------------------------------------------*/

module karabas_minig_top (
	//---------------------------
	input wire CLK_50MHZ,

	//---------------------------
	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,

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
	input wire FT_DE,
	output wire FT_CLK_OUT,

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

	output wire DAC_BCK,
	output wire DAC_WS,
	output wire DAC_DAT,

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
	inout wire [5:0] MCU_IO, // [0] burst cs_n, [1] burst ready, [2] sd2 cs_n, [3] ft cs_n

	//---------------------------
	output wire MIDI_TX,

	output wire ESP32_SPI_CS_N,
	input wire ESP32_PCM_BCK,
	input wire ESP32_PCM_RLCK,
	input wire ESP32_PCM_DAT,

	//---------------------------
	output wire FLASH_CS_N,
	input wire FLASH_DO,
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
assign ESP32_SPI_CS_N = 1'b1;
assign MIDI_TX = 1'b1;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;
assign FT_CLK_OUT = 1'b0;

//---------- clocks ------------

// 50 MHz * 12 = 600 MHz VCO: clk_sys 600 / 28 = 21.429 MHz (the SNES master clock, NTSC 21.477
// - 0.22 %: 59.97 Hz frames; the PFD of the PLL needs 19 MHz or more, so DIVCLK_DIVIDE is 1 or 2
// and this is the closest 4:1 pair), clk_mem 600 / 7 = 85.71 MHz = 4 x clk_sys, phase 0
wire [5:0] pll_clk;
wire locked;
kg_pll #(
	.CLKIN_PERIOD(20.0),
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(12),
	.CLKOUT0_DIVIDE(28),
	.CLKOUT1_DIVIDE(7),
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

// hdmi serial clock: 5 x clk_sys (the pixel clock) and its inverse
wire clk_hdmi, clk_hdmi_n, locked_hdmi;
kg_dcm #(
	.CLKIN_PERIOD(46.667),
	.CLKFX_MULTIPLY(5),
	.CLKFX_DIVIDE(1)
) dcm_hdmi(
	.clk_in(clk_sys),
	.rst(areset),
	.clk_fx(clk_hdmi),
	.clk_fx180(clk_hdmi_n),
	.clk_0(),
	.locked(locked_hdmi)
);

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
assign MCU_IO[5:2] = 4'bzzzz;

// Rev.G has MCU_SCK on a global clock pin: bursts at up to 32 MHz
kg_mcu #(
	.BURST_MAX_MHZ(32),
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
	.DVI_ONLY(),

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

snes_core #(.USE_DSPN(1)) core(
	.clk_sys(clk_sys),
	.clk_mem(clk_mem),
	.areset(areset),
	.softsw_command(softsw_command),
	.osd_command(osd_command),
	.mcu_busy(mcu_busy),
	.joy_l(joy_l),
	.joy_r(joy_r),
	.load_active(fileloader_active),
	.load_addr(fileloader_addr),
	.load_data(fileloader_data),
	.load_wr(fileloader_wr),
	.rgb(osd_rgb),
	.hs(hd_hs),
	.vs(hd_vs),
	.de(hd_de),
	.audio_l(audio_l),
	.audio_r(audio_r),
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

//---------- DVI ------------

// DVI (no HDMI audio for now: hdmi_tx of zhdmi is 2240 LUTs, the core does not fit with it; the
// sound is on the PCM5102 output). 640 x 480: negative syncs.
wire [9:0] enc_r, enc_g, enc_b;
dvi dvi(
	.CLK(clk_sys),
	.RESET(~locked_hdmi),
	.RGB(osd_rgb),
	.HSYNC(~hd_hs),
	.VSYNC(~hd_vs),
	.DE(hd_de),
	.ENC_RED(enc_r),
	.ENC_GREEN(enc_g),
	.ENC_BLUE(enc_b)
);

tmds_serializer ser_b(.clk(clk_sys), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(enc_b), .tx_d_n(TMDS_N[0]), .tx_d_p(TMDS_P[0]));
tmds_serializer ser_g(.clk(clk_sys), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(enc_g), .tx_d_n(TMDS_N[1]), .tx_d_p(TMDS_P[1]));
tmds_serializer ser_r(.clk(clk_sys), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(enc_r), .tx_d_n(TMDS_N[2]), .tx_d_p(TMDS_P[2]));
tmds_serializer ser_c(.clk(clk_sys), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(~locked_hdmi),
	.tmds_d(10'b1111100000), .tx_d_n(TMDS_N[3]), .tx_d_p(TMDS_P[3]));

//---------- audio DAC ------------

kg_pcm5102 pcm5102(
	.clk(clk_sys),
	.reset(areset),
	.left(audio_l),
	.right(audio_r),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_WS)
);

endmodule
