`timescale 1ns / 1ps

module spram #(
    parameter data_width_g = 8,
    parameter addr_width_g = 10
) (
    // Port A
    input   wire                clock,
    input   wire                clken,
    input   wire                wren,
    input   wire    [addr_width_g-1:0]  address,
    input   wire    [data_width_g-1:0]  data,
    output  reg     [data_width_g-1:0]  q
     
);

 
// Shared memory
reg [data_width_g-1:0] mem [(2**addr_width_g)-1:0];

always @(posedge clock) begin
    if (clken) 
    begin
      q      <= mem[address];
      if(wren) begin
        q      <= data;
        mem[address] <= data;
      end
    end
end
 
endmodule
