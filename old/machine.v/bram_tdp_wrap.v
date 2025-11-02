

module bram_tdp_wrap #
(
  parameter DATA_W = 16,
  parameter ADDR_W = 12
)
(
  input wire clk,
  input wire a_we,
  input wire [ADDR_W-1:0] a_addr,
  input wire [DATA_W-1:0] a_din,
  output reg [DATA_W-1:0] a_dout,
  input wire b_we,
  input wire [ADDR_W-1:0] b_addr,
  input wire [DATA_W-1:0] b_din,
  output reg [DATA_W-1:0] b_dout
);

  localparam DEPTH = 1 << ADDR_W;
  reg [DATA_W-1:0] mem [0:DEPTH-1];

  always @(posedge clk) begin
    if(a_we) mem[a_addr] <= a_din; 
    a_dout <= mem[a_addr];
    if(b_we) mem[b_addr] <= b_din; 
    b_dout <= mem[b_addr];
  end


endmodule

