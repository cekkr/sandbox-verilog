`include "sand_defs.vh"



module sand_circuit_neuron_relu #
(
  parameter DATA_W = 16,
  parameter FRAC_W = 8
)
(
  edge_in,
  raw_in,
  edge_gain_q,
  raw_gain_q,
  bias_q,
  threshold_q,
  raw_out,
  relu_out,
  fire
);

  input signed [DATA_W-1:0] edge_in;
  input signed [DATA_W-1:0] raw_in;
  input signed [DATA_W-1:0] edge_gain_q;
  input signed [DATA_W-1:0] raw_gain_q;
  input signed [DATA_W-1:0] bias_q;
  input signed [DATA_W-1:0] threshold_q;
  output signed [DATA_W-1:0] raw_out;reg signed [DATA_W-1:0] raw_out;
  output signed [DATA_W-1:0] relu_out;reg signed [DATA_W-1:0] relu_out;
  output fire;reg fire;
  localparam Q_MAX = (1 << DATA_W - 1) - 1;
  localparam Q_MIN = -(1 << DATA_W - 1);
  integer edge_term;
  integer raw_term;
  integer combined;

  function [31:0] clamp_signed;
    input [31:0] value;
    begin
      if(value > Q_MAX) clamp_signed = Q_MAX; 
      else if(value < Q_MIN) clamp_signed = Q_MIN; 
      else clamp_signed = value;
    end
  endfunction


  function [31:0] clamp_positive;
    input [31:0] value;
    begin
      if(value < 0) clamp_positive = 0; 
      else if(value > Q_MAX) clamp_positive = Q_MAX; 
      else clamp_positive = value;
    end
  endfunction


  always @(*) begin
    edge_term = $signed(edge_gain_q) * $signed(edge_in) >>> FRAC_W;
    raw_term = $signed(raw_gain_q) * $signed(raw_in) >>> FRAC_W;
    combined = edge_term + raw_term + $signed(bias_q);
    raw_out = clamp_signed(combined);
    if(combined > 0) relu_out = clamp_positive(combined); 
    else relu_out = { DATA_W{ 1'b0 } };
    fire = combined >= threshold_q;
  end


endmodule

