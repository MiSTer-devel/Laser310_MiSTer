`timescale 1ns / 1ps
/*============================================================================
	Aznable (custom 8-bit computer system) - Verilator emu module

	Author: Jim Gregory - https://github.com/JimmyStones/
	Version: 1.1
	Date: 2021-10-17

	This program is free software; you can redistribute it and/or modify it
	under the terms of the GNU General Public License as published by the Free
	Software Foundation; either version 3 of the License, or (at your option)
	any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program. If not, see <http://www.gnu.org/licenses/>.
===========================================================================*/

module emu (

	input clk_sys,
	input reset,
	input soft_reset,
	input menu,
	
	input [31:0] joystick_0,
	input [31:0] joystick_1,
	input [31:0] joystick_2,
	input [31:0] joystick_3,
	input [31:0] joystick_4,
	input [31:0] joystick_5,
	
	input [15:0] joystick_l_analog_0,
	input [15:0] joystick_l_analog_1,
	input [15:0] joystick_l_analog_2,
	input [15:0] joystick_l_analog_3,
	input [15:0] joystick_l_analog_4,
	input [15:0] joystick_l_analog_5,
	
	input [15:0] joystick_r_analog_0,
	input [15:0] joystick_r_analog_1,
	input [15:0] joystick_r_analog_2,
	input [15:0] joystick_r_analog_3,
	input [15:0] joystick_r_analog_4,
	input [15:0] joystick_r_analog_5,

	input [7:0] paddle_0,
	input [7:0] paddle_1,
	input [7:0] paddle_2,
	input [7:0] paddle_3,
	input [7:0] paddle_4,
	input [7:0] paddle_5,

	input [8:0] spinner_0,
	input [8:0] spinner_1,
	input [8:0] spinner_2,
	input [8:0] spinner_3,
	input [8:0] spinner_4,
	input [8:0] spinner_5,

	// ps2 alternative interface.
	// [8] - extended, [9] - pressed, [10] - toggles with every press/release
	input [10:0] ps2_key,

	// [24] - toggles with every event
	input [24:0] ps2_mouse,
	input [15:0] ps2_mouse_ext, // 15:8 - reserved(additional buttons), 7:0 - wheel movements

	// [31:0] - seconds since 1970-01-01 00:00:00, [32] - toggle with every change
	input [32:0] timestamp,

	output [7:0] VGA_R,
	output [7:0] VGA_G,
	output [7:0] VGA_B,
	
	output VGA_HS,
	output VGA_VS,
	output VGA_HB,
	output VGA_VB,

	output CE_PIXEL,
	
	output	[15:0]	AUDIO_L,
	output	[15:0]	AUDIO_R,
	
	input			ioctl_download,
	input			ioctl_wr,
	input [24:0]		ioctl_addr,
	input [7:0]		ioctl_dout,
	input [7:0]		ioctl_index,
	output reg		ioctl_wait=1'b0,

	output [31:0] 		sd_lba[2],
	output [9:0] 		sd_rd,
	output [9:0] 		sd_wr,
	input [9:0] 		sd_ack,
	input [8:0] 		sd_buff_addr,
	input [7:0] 		sd_buff_dout,
	output [7:0] 		sd_buff_din[2],
	input 			sd_buff_wr,
	input [9:0] 		img_mounted,
	input 			img_readonly,

	input [63:0] 		img_size



);
wire [15:0] joystick_a0 =  joystick_l_analog_0;

wire UART_CTS;
wire UART_RTS;
wire UART_RXD;
wire UART_TXD;
wire UART_DTR;
wire UART_DSR;

wire CLK_VIDEO = clk_sys;

wire  [7:0] pdl  = {~paddle_0[7], paddle_0[6:0]};
wire [15:0] joys = joystick_a0;
wire [15:0] joya = {joys[15:8], joys[7:0]};
wire  [5:0] joyd = joystick_0[5:0] & {2'b11, {2{~|joys[7:0]}}, {2{~|joys[15:8]}}};

assign AUDIO_L = {audio_l,6'b0};
assign AUDIO_R = {audio_r,6'b0};
wire [9:0] audio_l, audio_r;

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	reg div ;
	
	div <= ~div;
	ce_pix <=  &div ;
end
wire [15:0] hdd_sector;

assign sd_lba[1] = {16'b0,hdd_sector};

wire led;
wire hbl,vbl;
always @(posedge clk_sys) begin
	//if (soft_reset) $display("soft_reset %x",soft_reset);
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

wire clk_10=clk_sys;
wire clk_42=clk_sys;

LASER310_TOP LASER310_TOP(
        .CLK10MHZ(clk_10),
        .CLK42MHZ(clk_42),
        .RESET(~reset),
        .VGA_RED(VGA_R),
        .VGA_GREEN(VGA_G),
        .VGA_BLUE(VGA_B),
        .VGA_HS(VGA_HS),
        .VGA_VS(VGA_VS),
        .h_blank(VGA_HB),
        .v_blank(VGA_VB),
        .ce_pix(CE_PIXEL),
        .AUD_ADCDAT(),
//      .VIDEO_MODE(1'b0),
        .audio_s(audiomix),
        .key_strobe     (key_strobe     ),
        .key_pressed    (key_pressed    ),
        .key_code       (key_code[7:0]       ),

        .dn_index(ioctl_index),
        .dn_data(ioctl_dout),
        .dn_addr(ioctl_addr[15:0]),
        .dn_wr(ioctl_wr),
        .dn_download(ioctl_download),
        .led(LED),
        .led2(LED2),

	//"O5,Turbo,Off,On;",
        //"O6,Dos Rom,Off,On;",
        //"O7,SHRG,Off,On;",
        //.SWITCH({"0000",status[10],~status[7],status[6],status[5]}),
        .SWITCH({6'b0, 1'b0, 1'b1, 1'b0, 1'b1}),
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
        .up_2(joystick_1[3])

        );



endmodule 

