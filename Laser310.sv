//============================================================================
//  Laser310 port to MiSTer
//  Copyright (c) 2019,2020 Alan Steremberg - alanswx
//
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

//`define SOUND_DBG
assign VGA_SCALER = 0;
assign VGA_F1 = 0;
assign VGA_DISABLE = 0;

assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign USER_OUT = '1;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
assign ADC_BUS  = 'Z;
assign {SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 6'b111111;
assign SDRAM_DQ = 'Z;

assign BUTTONS = 0;

assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign LED_USER  = LED2/*ioctl_download*/;


wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
assign VGA_SL = sl[1:0];

wire [1:0] ar = status[9:8];
// VIDEO_ARX/ARY come from video_freak (below the video_mixer).

`include "build_id.v"
localparam CONF_STR = {
        "Laser;;",
        "-;",
        "F1,VZ ,Load VZ Image;",
        "S0,WAVCAS,Tape;",
        "S1,DSK,Disk 1;",
        "S2,DSK,Disk 2;",
        "-;",
        "OK,Video standard,PAL (50 Hz),NTSC (60 Hz);",
        "O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "O[22:21],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
        "O24,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",

        "O5,Turbo,Off,On;",
        "O6,Disk drives (DOS),Off,On;",
        "O7,SHRG,On,Off;",
        "OB,Load hints,On,Off;",
        "OC,Tape speed,3x,Normal;",
        "OD,Tape overlay,On,Off;",
        "OE,Tape audio,Off,On;",
        "OG,Tape deck,Auto,Play;",
        "OH,Tape polarity,Normal,Inverted;",
        "OIJ,Tape pitch,Auto,Normal,+6%,+12%;",
     //   "O8,64x32 Video,Off,On;",

        "-;",
        "RF,Rewind tape;",
        "R0,Reset;",
        "I,Tape ready (rewound),Tape format not supported;",
		  "J,Fire 1,Button 2;",
        "V,v",`BUILD_DATE
};

wire LED;
wire LED2;

wire [127:0] status;
wire  [1:0] buttons;
wire        ioctl_download;
wire        ioctl_wr;
wire [15:0] ioctl_addr;
wire  [7:0] ioctl_data;
wire  [7:0] ioctl_index;

wire        forced_scandoubler;
wire [10:0] ps2_key;
//wire [24:0] ps2_mouse;
wire [21:0] gamma_bus;

wire [15:0] joystick_0, joystick_1;


// tape image slot and the OSD info message on mount ("I," in CONF_STR)
// S0 tape, S1/S2 floppy drives 1 and 2 (rtl/vz_floppy.sv)
wire  [2:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba, disk_sd_lba;
wire  [2:0] sd_ack;
wire        sd_rd, sd_buff_wr;
wire  [1:0] disk_sd_rd, disk_sd_wr;
wire  [7:0] disk_sd_buff_din;
wire        disk_activity;
assign LED_DISK  = {1'b0, LED | disk_activity};   // drive selected or .VZ loading
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire        tape_ready, tape_bad;
reg         info_req;
reg   [7:0] info;

hps_io #(.CONF_STR(CONF_STR), .PS2DIV(32), .VDNUM(3)) hps_io
(
        .clk_sys(clk_sys),
        .HPS_BUS(HPS_BUS),

        .joystick_0(joystick_0),
        .joystick_1(joystick_1),
        .buttons(buttons),
        .forced_scandoubler(forced_scandoubler),
        .gamma_bus(gamma_bus),


        .status(status),

        .ioctl_download(ioctl_download),
        .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_data),
        .ioctl_index(ioctl_index),
        .ps2_key(ps2_key),

        // tape (S0), disks (S1, S2)
        .img_mounted(img_mounted),
        .img_readonly(img_readonly),
        .img_size(img_size),
        .sd_lba('{sd_lba, disk_sd_lba, disk_sd_lba}),
        .sd_blk_cnt('{6'd0, 6'd0, 6'd0}),
        .sd_rd({disk_sd_rd, sd_rd}),
        .sd_wr({disk_sd_wr, 1'b0}),
        .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_din('{8'd0, disk_sd_buff_din, disk_sd_buff_din}),
        .sd_buff_wr(sd_buff_wr),

        .info_req(info_req),
        .info(info),

        .ps2_kbd_clk_out    ( ps2_kbd_clk    ),
        .ps2_kbd_data_out   ( ps2_kbd_data   )
);

wire reset;
wire rom_download = ioctl_download && !ioctl_index;
assign reset = (RESET | status[0] | buttons[1] | rom_download  );

wire ps2_kbd_clk;
wire ps2_kbd_data;

assign clk_sys  = clk_42; 

always @(posedge clk_sys) begin
        info_req <= 0;
        if (tape_ready) begin info <= 8'd1; info_req <= 1; end
        if (tape_bad)   begin info <= 8'd2; info_req <= 1; end
end
wire       key_pressed = ps2_key[9];
wire [8:0] key_code    = ps2_key[8:0];
reg key_strobe;
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];
	
	if(old_state != ps2_key[10]) begin
	   key_strobe <= ~ key_strobe;
end
end

LASER310_TOP LASER310_TOP(
        .CLK10MHZ(clk_10),
        .CLK42MHZ(clk_42),
        .RESET(~reset),
        .VGA_RED(r),
        .VGA_GREEN(g),
        .VGA_BLUE(b),
        .VGA_HS(hs),
        .VGA_VS(vs),
        .h_blank(hblank),
        .v_blank(vblank),
        .ce_pix(ce_pix),
        .AUD_ADCDAT(),
//      .VIDEO_MODE(1'b0),
        .audio_s(audiomix),
        .key_strobe     (key_strobe     ),
        .key_pressed    (key_pressed    ),
        .key_code       (key_code       ),

        .dn_index(ioctl_index),
        .dn_data(ioctl_data),
        .dn_addr(ioctl_addr[15:0]),
        .dn_wr(ioctl_wr),
        .dn_download(ioctl_download),
        .led(LED),
        .led2(LED2),
        // SWITCH[2] = SHRG enable = ~status[7]: OSD "SHRG: On" (the default, status 0) enables it.
        .SWITCH({6'b000000,status[10],~status[7],status[6],status[5]}),
        .UART_RXD(),
        .UART_TXD(),
	// joystick
        .arm_1(joystick_0[5]),
        .fire_1(joystick_0[4]),
        .right_1(joystick_0[0]),
        .left_1(joystick_0[1]),
        .down_1(joystick_0[2]),
        .up_1(joystick_0[3]),
        .arm_2(joystick_1[5]),
        .fire_2(joystick_1[4]),
        .right_2(joystick_1[0]),
        .left_2(joystick_1[1]),
        .down_2(joystick_1[2]),
        .up_2(joystick_1[3]),
        .cass_in(1'b0),          // sim-only direct drive; the tape player is inside (vz_tape.sv)
        .hint_en(~status[11]),   // OB Load hints, On by default
        .tape_overlay_en(~status[13]),
        .tape_turbo_en(~status[12]),
        .tape_audio_en(status[14]),
        .video_pal(~status[20]),
        .tape_deck_play(status[16]),
        .tape_invert(status[17]),
        .tape_pitch((status[19:18] == 2'd0 ? 2'd3 : status[19:18] - 2'd1)),   // OSD Auto (default) / Normal / +6% / +12%
        .tape_rewind(status[15]),
        .img_mounted(img_mounted[0]),
        .img_size(img_size),
        .sd_lba(sd_lba),
        .sd_rd(sd_rd),
        .sd_ack(sd_ack[0]),
        .sd_buff_addr(sd_buff_addr[8:0]),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_wr(sd_buff_wr),
        .tape_ready(tape_ready),
        .tape_bad(tape_bad),
        .disk_img_mounted(img_mounted[2:1]),
        .img_readonly(img_readonly),
        .disk_sd_lba(disk_sd_lba),
        .disk_sd_rd(disk_sd_rd),
        .disk_sd_wr(disk_sd_wr),
        .disk_sd_ack(sd_ack[2:1]),
        .disk_sd_buff_din(disk_sd_buff_din),
        .disk_activity(disk_activity)

        );

wire clk_vid;
//assign CE_PIXEL = clk_vid;
assign CLK_VIDEO = clk_42;

wire ce_pix;
///////////////////////////////////////////////////
//wire clk_sys, clk_ram, clk_ram2, clk_pixel, locked;
//
wire [2:0] scale = status[4:2];
wire  [7:0] r,g,b;
wire       scandoubler = (scale || forced_scandoubler);
wire freeze_sync;

video_mixer #(.LINE_LENGTH(800),.GAMMA(1)) video_mixer
(
        .*,

        .ce_pix(ce_pix),

        .hq2x(scale==1),

        .R(r),
        .G(g),
        .B(b),

        // Positive pulses.
        .HSync(hs),
        .VSync(vs),
        .HBlank(hblank),
        .VBlank(vblank),

        .VGA_DE(vga_de)
);

// Original aspect (video-standard.md, Sizes): the core sends 256 x 192
// active pixels (no border) at 42.954545 / 6 = 7.1591 MHz (2 x fsc).
// PAR = 6.1364 / 7.1591 = 6/7, so 256 x 6/7 : 192 = 1536:1344 = 8:7 (1.14).
// The PAL mode keeps the same pixel clock and 192 active lines.
wire vga_de;
video_freak video_freak
(
        .*,
        .VGA_DE_IN(vga_de),
        .ARX((!ar) ? 12'd8 : (ar - 1'd1)),
        .ARY((!ar) ? 12'd7 : 12'd0),
        .CROP_SIZE(12'd0),
        .CROP_OFF(5'd0),
        .SCALE({1'b0, status[22:21]})
);

//
//
wire clk_sys,locked;
wire hs,vs,hblank,vblank;

wire [15:0] audiomix;		// signed

assign AUDIO_L=audiomix;
assign AUDIO_R=AUDIO_L;


wire clk_42, clk_10;
wire pll_locked;


  
  
pll pll
  (
   .refclk   (CLK_50M),
   .rst      (0),
   .locked   (pll_locked),     // PLL is running stable
   .outclk_0 (clk_42),         // 42 MHz
   .outclk_1 (clk_10)         // 10 MHz

   );

  
  
  
endmodule



