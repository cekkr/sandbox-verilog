`include "sand_defs.vh"



module sand_circuit_activation_micro_lut
(
  input signed [16-1:0] value_in,
  input wire signed [16-1:0] micro_lut [0:15],
  output signed [16-1:0] value_out
);

  localparam Q_ONE = 1 << 8;
  integer abs_val;
  reg [1:0] bucket;
  reg frac_flag;
  reg [3:0] lut_idx;
  reg signed [16-1:0] lut_val;

  always @(*) begin
    abs_val = (value_in[16 - 1])? -$signed(value_in) : $signed(value_in);
    if(abs_val >= (Q_ONE << 1)) bucket = 2'd3; 
    else if(abs_val >= (Q_ONE * 3 >> 1)) bucket = 2'd2; 
    else if(abs_val >= (Q_ONE >> 1)) bucket = 2'd1; 
    else bucket = 2'd0;
    if(8 > 0) frac_flag = (abs_val >> 8 - 1) & 1'b1; 
    else frac_flag = 1'b0;
    lut_idx = { value_in[16 - 1], bucket, frac_flag };
    lut_val = micro_lut[lut_idx];
  end

  assign value_out = lut_val;

endmodule

