`include "sand_defs.vh"



module sand_circuit_edge_l1 #
(
  parameter DATA_W = 16
)
(
  center,
  north,
  south,
  east,
  west,
  edge_out
);

  input signed [DATA_W-1:0] center;
  input signed [DATA_W-1:0] north;
  input signed [DATA_W-1:0] south;
  input signed [DATA_W-1:0] east;
  input signed [DATA_W-1:0] west;
  output [DATA_W-1:0] edge_out;reg [DATA_W-1:0] edge_out;
  localparam Q_MAX = (1 << DATA_W - 1) - 1;
  integer dx;
  integer dy;
  integer abs_dx;
  integer abs_dy;
  integer sum;

  always @(*) begin
    dx = $signed(east) - $signed(west);
    if(dx < 0) abs_dx = -dx; 
    else abs_dx = dx;
    dy = $signed(south) - $signed(north);
    if(dy < 0) abs_dy = -dy; 
    else abs_dy = dy;
    sum = abs_dx + abs_dy;
    if(sum < 0) sum = 0; 
    else if(sum > Q_MAX) sum = Q_MAX; 
    edge_out = sum;
  end


endmodule

