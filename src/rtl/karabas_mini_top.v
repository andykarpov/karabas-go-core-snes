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
	inout wire [3:0] MCU_IO, // [1] INT of link v2, [2] sd2 cs_n, [3] ft cs_n
	
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
// karabas: made by src/tools/mktops.py from karabas_minig_top.v (do not edit it, change Mini G)

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
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign FT_RESET = 1'b1;
assign MIDI_TX = 1'b1;
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
	.CLKOUT3_DIVIDE(75),
	.BUFG_MASK(6'b001011)
) pll(
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(locked)
);
wire clk_sys = pll_clk[0];
wire clk_mem = pll_clk[1];
wire areset = ~locked;

// the clock of the FT812 (600 / 75 = 8 MHz): it must always have one (karabas-go-notes ft-clk-out-required)
wire clk_8 = pll_clk[3];
ODDR2 oddr_ft_clk (.Q(FT_CLK_OUT), .C0(clk_8), .C1(~clk_8), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

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
wire dvi_only;                  // kg_mcu2 (the firmware setting): no HDMI islands (snes_hdmi)
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

//---------- MCU: link v2 (karabas-go-firmware docs/link_v2.md, kg_mcu2); INT on IO1 ------------

wire [55:0] kbd;
wire [7:0] hid_kb_dat0 = kbd[15:8], hid_kb_dat1 = kbd[23:16], hid_kb_dat2 = kbd[31:24],
	hid_kb_dat3 = kbd[39:32], hid_kb_dat4 = kbd[47:40], hid_kb_dat5 = kbd[55:48];
wire [15:0] joy_l16, joy_r16;
wire [12:0] joy_l = joy_l16[12:0], joy_r = joy_r16[12:0];
wire [1:0] ld_kind;
wire [7:0] ld_data;
wire [31:0] ld_addr;
wire ld_active, ld_wr;
wire [4*8-1:0] sw;
wire mcu_busy;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

wire mcu_int;
assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[3:2] = 2'bzz;

// the ROM image: the file loader (LD kind 1)
wire fileloader_active = ld_active && ld_kind == 2'd1;
wire fileloader_wr = ld_wr && ld_kind == 2'd1;
wire [31:0] fileloader_addr = ld_addr;
wire [7:0] fileloader_data = ld_data;

// clk_sys 21.4 MHz: below 4 x the 16 MHz sck of spi_freq (the upper bound of kg_l2_link)
kg_mcu2 #(
	.SW_N(4),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_FT(1),
	.ENABLE_SD2(1)
) mcu(
	.CLK(clk_sys),
	.N_RESET(~areset),

	.MCU_SCK(MCU_SCK),
	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SS(MCU_CS_N),
	.MCU_INT(mcu_int),
	.MCU_SPI_FT_SS(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),

	.SW(sw), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(dvi_only), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(mcu_busy), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

	.KBD(kbd), .KBD_WR(), .PS2_CODE(), .PS2_KIND(), .PS2_WR(),
	.MS_X(), .MS_Y(), .MS_Z(), .MS_B(), .MS_WR(),
	.JOY_L(joy_l16), .JOY_R(joy_r16), .JOY_WR(),
	.PS2_CMD(16'h0000), .PS2_CMD_WR(1'b0),

	.LD_KIND(ld_kind), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(ld_active), .LD_END(),
	.LD_ADDR(ld_addr), .LD_DATA(ld_data), .LD_WR(ld_wr), .LD_READY(1'b1),

	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(), .SDC_IMG_SIZE(),
	.SDC_RD(8'd0), .SDC_WR(8'd0), .SDC_SECTOR(32'd0),
	.SDC_BUSY(), .SDC_DONE(), .SDC_ERROR(), .SDC_SLOT(),
	.SDC_BYTE_IN_STROBE(), .SDC_BYTE_ADDR(), .SDC_BYTE_IN_DATA(), .SDC_BYTE_OUT_DATA(8'd0),
	.IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .IMG_ACTIVE(),

	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'b1111), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .RTC_DO(),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),

	.FT_SPI_ON(), .FT_VGA_ON(), .FT_RESET(),
	.FT_SCK(FT_SPI_SCK), .FT_MOSI(FT_SPI_MOSI), .FT_MISO(FT_SPI_MISO), .FT_CS_N(FT_SPI_CS_N),
	.SD2_SCK(SD_CLK), .SD2_MOSI(SD_DI), .SD2_MISO(SD_DO), .SD2_CS_N(SD_CS_N)
);

//---------- SNES: soft switches, joysticks, the SNES, 31 kHz video, OSD ------------

wire [23:0] core_rgb, osd_rgb;
wire core_hs, core_vs, core_de, hd_hs, hd_vs, hd_de;
wire [15:0] audio_l, audio_r;
wire audio_lrck;

snes_core #(.USE_DSPN(1), .LINK(2)) core(
	.clk_sys(clk_sys),
	.clk_mem(clk_mem),
	.clk_pix(clk_pix),
	.areset(areset),
	.softsw_command(16'd0),
	.osd_command(16'd0),
	.sw_regs(sw),
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
	.rgb(core_rgb),
	.hs(core_hs),
	.vs(core_vs),
	.de(core_de),
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

//---------- OSD ------------

// the bitmap OSD of link v2 (kg_l2_osd_overlay): written in clk_sys, drawn in clk_pix, centred in de,
// the scale from its size, 2 clocks of latency with its syncs and de
kg_l2_osd_overlay osd (
	.wclk(clk_sys),
	.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on(8'd0), .icon_act(8'd0),
	.clk(clk_pix),
	.rgb_i(core_rgb), .hs_i(core_hs), .vs_i(core_vs), .de_i(core_de),
	.rgb_o(osd_rgb), .hs_o(hd_hs), .vs_o(hd_vs), .de_o(hd_de)
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
kg_sigma_delta_dac dac_l(.clk(clk_sys), .reset(areset), .din({2'b00, ~audio_l[15], audio_l[14:4], 2'b00}), .dout(AUDIO_L));
kg_sigma_delta_dac dac_r(.clk(clk_sys), .reset(areset), .din({2'b00, ~audio_r[15], audio_r[14:4], 2'b00}), .dout(AUDIO_R));

endmodule
