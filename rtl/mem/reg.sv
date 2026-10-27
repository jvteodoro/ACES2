`timescale 1ns/1ps

module reg_module
  #(parameter DATA_WIDTH=32)
  (
       input                   clk,
       input                   rst,
       input                   we,
       input [DATA_WIDTH-1:0]  in,
       output [DATA_WIDTH-1:0] out
);

   reg [DATA_WIDTH-1:0] mem;

   assign out = mem;

   always @(posedge clk) begin
      if (rst)
        mem <= '0;
      else if (we)
        mem <= in;
   end
   
endmodule
