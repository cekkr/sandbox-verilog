`include "sand_defs.vh"



module sand_circuit_activation_softsign
(
  input signed [16-1:0] value_in,
  output signed [16-1:0] value_out
);

  localparam Q_ONE_INT = 1 << 8;
  localparam signed [16-1:0] Q_MAX = (1 << 16 - 1) - 1;
  localparam signed [16-1:0] Q_MIN = -(1 << 16 - 1);
  integer numerator;
  integer denominator;
  integer abs_val;
  integer scaled;
  reg signed [16-1:0] result;

  always @(*) begin
    numerator = $signed(value_in);
    abs_val = (value_in[16 - 1])? -$signed(value_in) : $signed(value_in);
    denominator = abs_val + Q_ONE_INT;
    if(denominator <= 0) denominator = 1; 
    scaled = numerator8;
    if(scaled >= 0) scaled = scaled + (denominator >> 1); 
    else scaled = scaled - (denominator >> 1);
    result = $signed((scaled / denominator));
    if(result > Q_MAX) result = Q_MAX; 
    else if(result < Q_MIN) result = Q_MIN; 
  end

  assign value_out = result;

endmodule

