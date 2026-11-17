//-------------------------------------------------------------------------------------------------
module sprom
//-------------------------------------------------------------------------------------------------
#
(
	parameter init_file  = "rom8x16K.hex",
	parameter widthad_a = 14,
	parameter width_a = 8
)
(
	input  wire         clock,
	output reg [width_a-1:0] q,
	input  wire[widthad_a-1:0] address
);
//-------------------------------------------------------------------------------------------------

reg[width_a-1:0] d[(2**widthad_a)-1:0];
initial $readmemh(init_file, d, 0);

always @(posedge clock) q<= d[address];

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------

//-------------------------------------------------------------------------------------------------
// The same ROM with a write port, so the OSD's Load ROM (ioctl index 0) can replace
// its contents. Simple dual port: write on wr_*, read on address.
module sprom_wr
#(
	parameter init_file  = "rom8x16K.hex",
	parameter widthad_a = 14,
	parameter width_a = 8
)
(
	input  wire         clock,
	output reg [width_a-1:0] q,
	input  wire[widthad_a-1:0] address,
	input  wire         wr,
	input  wire[widthad_a-1:0] wr_address,
	input  wire[width_a-1:0] wr_data
);

reg[width_a-1:0] d[(2**widthad_a)-1:0];
initial $readmemh(init_file, d, 0);

always @(posedge clock) begin
	if (wr) d[wr_address] <= wr_data;
	q <= d[address];
end

endmodule
