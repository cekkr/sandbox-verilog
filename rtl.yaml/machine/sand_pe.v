`include "sand_defs.vh"
`include "sand_math.vh"



module sand_pe #
(
  parameter DATA_W = 16,
  parameter FRAC_W = 8
)
(
  input wire clk,
  input wire rst,
  input wire [DATA_W-1:0] self_in,
  input wire [DATA_W-1:0] n_in,
  input wire [DATA_W-1:0] s_in,
  input wire [DATA_W-1:0] e_in,
  input wire [DATA_W-1:0] w_in,
  input wire [DATA_W-1:0] ne_in,
  input wire [DATA_W-1:0] nw_in,
  input wire [DATA_W-1:0] se_in,
  input wire [DATA_W-1:0] sw_in,
  input wire [DATA_W-1:0] above_in,
  input wire [DATA_W-1:0] below_in,
  input wire [5-1:0] opcode,
  input wire use_diagonals,
  input wire [DATA_W-1:0] constA,
  input wire [DATA_W-1:0] constB,
  input wire [DATA_W-1:0] constC,
  input wire [DATA_W-1:0] constD,
  input wire unit_flux_enable,
  input wire unit_overflow_reverse_top,
  input wire unit_overflow_reverse_bottom,
  input wire unit_pressure_diag_override,
  input wire [7:0] unit_pressure_iters,
  input wire [DATA_W-1:0] unit_weight_top,
  input wire [DATA_W-1:0] unit_weight_bottom,
  input wire [DATA_W-1:0] unit_weight_side,
  input wire [DATA_W-1:0] unit_weight_retain,
  input wire [DATA_W-1:0] unit_weight_prev,
  input wire [DATA_W-1:0] unit_flux_threshold,
  input wire [DATA_W-1:0] unit_flux_reverse_top,
  input wire [DATA_W-1:0] unit_flux_reverse_bottom,
  input wire [DATA_W-1:0] unit_pressure_gain,
  input wire [DATA_W-1:0] unit_backprop_lr,
  input wire [DATA_W-1:0] unit_backprop_neigh,
  input wire [DATA_W-1:0] unit_backprop_decay,
  input wire [DATA_W-1:0] micro_lut [0:15],
  output reg [DATA_W-1:0] next_out
);

  localparam EXT_W = DATA_W + 4;

  function [DATA_W-1:0] fp_add;
    input [DATA_W-1:0] a;input [DATA_W-1:0] b;
    begin
      fp_add = a + b;
    end
  endfunction


  function [DATA_W-1:0] fp_sub;
    input [DATA_W-1:0] a;input [DATA_W-1:0] b;
    begin
      fp_sub = a - b;
    end
  endfunction


  function [DATA_W-1:0] fp_mul_const;
    input [DATA_W-1:0] a;input [DATA_W-1:0] c;
    begin
      fp_mul_const = a * c >>> FRAC_W;
    end
  endfunction


  function [DATA_W-1:0] fp_div_const;
    input [DATA_W-1:0] a;input [DATA_W-1:0] c;
    begin
      fp_div_const = (c == { DATA_W{ 1'b0 } })? { DATA_W{ 1'b0 } } : aFRAC_W / c;
    end
  endfunction


  function signed [EXT_W-1:0] directional_flow;
    input [DATA_W-1:0] self_val;
    input [DATA_W-1:0] neighbor_val;
    input [DATA_W-1:0] channel_coeff;
    input [DATA_W-1:0] friction_coeff;
    reg signed [EXT_W-1:0] self_ext;
    reg signed [EXT_W-1:0] neigh_ext;
    reg signed [EXT_W-1:0] delta_ext;
    reg [EXT_W-1:0] delta_abs_ext;
    reg [DATA_W-1:0] delta_abs;
    reg [DATA_W-1:0] delta_eff;
    reg [DATA_W-1:0] flow_mag;
    reg signed [EXT_W-1:0] flow_signed;
    begin
      self_ext = { { EXT_W - DATA_W{ self_val[DATA_W - 1] } }, self_val };
      neigh_ext = { { EXT_W - DATA_W{ neighbor_val[DATA_W - 1] } }, neighbor_val };
      delta_ext = neigh_ext - self_ext;
      delta_abs_ext = (delta_ext[EXT_W - 1])? -delta_ext : delta_ext;
      delta_abs = delta_abs_ext[DATA_W-1:0];
      if(|delta_abs_ext[EXT_W-1:DATA_W]) delta_abs = { DATA_W{ 1'b1 } }; 
      if(delta_abs <= friction_coeff) begin
        flow_signed = { EXT_W{ 1'b0 } };
      end else begin
        delta_eff = fp_sub(delta_abs, friction_coeff);
        flow_mag = fp_mul_const(delta_eff, channel_coeff);
        flow_signed = (delta_ext[EXT_W - 1])? -{ { EXT_W - DATA_W{ flow_mag[DATA_W - 1] } }, flow_mag } : { { EXT_W - DATA_W{ flow_mag[DATA_W - 1] } }, flow_mag };
      end
      directional_flow = flow_signed;
    end
  endfunction

  reg [DATA_W+3:0] sum_nbrs;
  reg [DATA_W-1:0] avg_nbrs;
  reg [DATA_W-1:0] min_nbr;reg [DATA_W-1:0] max_nbr;
  reg [DATA_W+2:0] sum4_only;
  wire [DATA_W-1:0] nb4 [0:3];
  assign nb4[0] = n_in;
  assign nb4[1] = s_in;
  assign nb4[2] = e_in;
  assign nb4[3] = w_in;
  wire [DATA_W-1:0] nb8 [0:7];
  assign nb8[0] = n_in;
  assign nb8[1] = s_in;
  assign nb8[2] = e_in;
  assign nb8[3] = w_in;
  assign nb8[4] = ne_in;
  assign nb8[5] = nw_in;
  assign nb8[6] = se_in;
  assign nb8[7] = sw_in;
  wire diag_active;assign diag_active = use_diagonals || unit_pressure_diag_override && (opcode == 5'd13);
  integer i;
  integer iter;
  reg signed [EXT_W-1:0] flux_accum;
  reg signed [EXT_W-1:0] flow_term;
  reg [DATA_W-1:0] retain_val;
  reg [DATA_W-1:0] prev_val;
  reg [EXT_W-1:0] cap_ext;
  reg [DATA_W-1:0] friction_top;
  reg [DATA_W-1:0] friction_bottom;
  reg [DATA_W-1:0] friction_side;
  reg [7:0] iter_limit;
  reg [DATA_W-1:0] gain_sel;
  reg [DATA_W-1:0] delta_val;
  reg [DATA_W-1:0] pressure_val;
  reg [DATA_W-1:0] lr_sel;
  reg [DATA_W-1:0] neigh_sel;
  reg [DATA_W-1:0] decay_sel;
  reg [DATA_W-1:0] err;
  reg [DATA_W-1:0] grad_term;
  reg [DATA_W-1:0] neigh_term;
  reg [DATA_W-1:0] decay_term;
  reg [DATA_W-1:0] update_term;
  reg [DATA_W-1:0] lap_gain;
  reg [DATA_W-1:0] sharpen_val;
  reg [DATA_W-1:0] edge_mag;
  reg [DATA_W-1:0] mix_self;
  reg [DATA_W-1:0] mix_avg;
  reg [DATA_W-1:0] mix_sum;
  reg [DATA_W-1:0] acc;

  always @(*) begin
    sum_nbrs = { DATA_W + 4{ 1'b0 } };
    sum4_only = { DATA_W + 3{ 1'b0 } };
    min_nbr = { DATA_W{ 1'b1 } };
    max_nbr = { DATA_W{ 1'b0 } };
    for(i=0; i<4; i=i+1) begin
      sum4_only = sum4_only + nb4[i];
      if(nb4[i] < min_nbr) min_nbr = nb4[i]; 
      if(nb4[i] > max_nbr) max_nbr = nb4[i]; 
    end
    if(!diag_active) begin
      sum_nbrs = { 1'b0, sum4_only };
      avg_nbrs = sum4_only[DATA_W-1:0] >> 2;
    end else begin
      sum_nbrs = { 1'b0, sum4_only };
      for(i=4; i<8; i=i+1) begin
        sum_nbrs = sum_nbrs + nb8[i];
        if(nb8[i] < min_nbr) min_nbr = nb8[i]; 
        if(nb8[i] > max_nbr) max_nbr = nb8[i]; 
      end
      avg_nbrs = sum_nbrs[DATA_W-1:0] >> 3;
    end
    if(above_in < min_nbr) min_nbr = above_in; 
    if(above_in > max_nbr) max_nbr = above_in; 
    if(below_in < min_nbr) min_nbr = below_in; 
    if(below_in > max_nbr) max_nbr = below_in; 
  end

  wire [3:0] micro_idx;assign micro_idx = { opcode[1:0], self_in[1:0] };
  wire [DATA_W-1:0] micro_val;assign micro_val = micro_lut[micro_idx];
  wire signed [EXT_W-1:0] self_s;assign self_s = { { EXT_W - DATA_W{ self_in[DATA_W - 1] } }, self_in };
  wire signed [EXT_W-1:0] above_s;assign above_s = { { EXT_W - DATA_W{ above_in[DATA_W - 1] } }, above_in };
  wire signed [EXT_W-1:0] below_s;assign below_s = { { EXT_W - DATA_W{ below_in[DATA_W - 1] } }, below_in };
  wire signed [EXT_W-1:0] n_s;assign n_s = { { EXT_W - DATA_W{ n_in[DATA_W - 1] } }, n_in };
  wire signed [EXT_W-1:0] s_s;assign s_s = { { EXT_W - DATA_W{ s_in[DATA_W - 1] } }, s_in };
  wire signed [EXT_W-1:0] e_s;assign e_s = { { EXT_W - DATA_W{ e_in[DATA_W - 1] } }, e_in };
  wire signed [EXT_W-1:0] w_s;assign w_s = { { EXT_W - DATA_W{ w_in[DATA_W - 1] } }, w_in };
  wire signed [EXT_W-1:0] dx_signed;assign dx_signed = e_s - w_s;
  wire signed [EXT_W-1:0] dy_signed;assign dy_signed = s_s - n_s;
  wire signed [EXT_W-1:0] dx_signed_neg;assign dx_signed_neg = -dx_signed;
  wire signed [EXT_W-1:0] dy_signed_neg;assign dy_signed_neg = -dy_signed;
  wire [DATA_W-1:0] dx_abs;assign dx_abs = (dx_signed[EXT_W - 1])? dx_signed_neg[DATA_W-1:0] : dx_signed[DATA_W-1:0];
  wire [DATA_W-1:0] dy_abs;assign dy_abs = (dy_signed[EXT_W - 1])? dy_signed_neg[DATA_W-1:0] : dy_signed[DATA_W-1:0];
  wire signed [EXT_W-1:0] sum4_signed;assign sum4_signed = n_s + s_s + e_s + w_s;
  wire signed [EXT_W-1:0] sum3d_signed;assign sum3d_signed = sum4_signed + above_s + below_s;
  wire signed [EXT_W-1:0] self_x4;assign self_x4 = self_s2;
  wire signed [EXT_W-1:0] self_x2;assign self_x2 = self_s1;
  wire signed [EXT_W-1:0] self_x6;assign self_x6 = self_x4 + self_x2;
  wire signed [EXT_W-1:0] laplacian_signed;assign laplacian_signed = sum3d_signed - self_x6;
  wire [DATA_W-1:0] laplacian;assign laplacian = laplacian_signed[DATA_W-1:0];
  wire [DATA_W-1:0] sum_planar;assign sum_planar = sum_nbrs[DATA_W-1:0];
  wire [DATA_W-1:0] sum_with_vert;assign sum_with_vert = fp_add(fp_add(sum_planar, above_in), below_in);
  reg [DATA_W-1:0] alu_res;

  always @(*) begin
    case(opcode)
      5'd0: alu_res = self_in;
      5'd1: alu_res = self_in;
      5'd2: alu_res = sum_nbrs[DATA_W-1:0];
      5'd3: alu_res = avg_nbrs;
      5'd4: alu_res = fp_add(self_in, constA);
      5'd5: alu_res = fp_sub(self_in, constA);
      5'd6: alu_res = fp_mul_const(self_in, constA);
      5'd7: alu_res = fp_div_const(self_in, constA);
      5'd8: begin
        alu_res = fp_add(self_in, fp_mul_const(fp_sub(avg_nbrs, self_in), constA));
      end
      5'd9: alu_res = (self_in < min_nbr)? self_in : min_nbr;
      5'd10: alu_res = (self_in > max_nbr)? self_in : max_nbr;
      5'd11: alu_res = (self_in < constA)? constA : 
                (self_in > constB)? constB : self_in;
      5'd12: begin
        if(!unit_flux_enable) begin
          retain_val = fp_mul_const(self_in, constA);
          flux_accum = { { EXT_W - DATA_W{ retain_val[DATA_W - 1] } }, retain_val };
          flow_term = directional_flow(self_in, n_in, constC, constD);
          flux_accum = flux_accum + flow_term;
          flow_term = directional_flow(self_in, s_in, constC, constD);
          flux_accum = flux_accum + flow_term;
          flow_term = directional_flow(self_in, e_in, constC, constD);
          flux_accum = flux_accum + flow_term;
          flow_term = directional_flow(self_in, w_in, constC, constD);
          flux_accum = flux_accum + flow_term;
          if(diag_active) begin
            flow_term = directional_flow(self_in, ne_in, constC, constD);
            flux_accum = flux_accum + flow_term;
            flow_term = directional_flow(self_in, nw_in, constC, constD);
            flux_accum = flux_accum + flow_term;
            flow_term = directional_flow(self_in, se_in, constC, constD);
            flux_accum = flux_accum + flow_term;
            flow_term = directional_flow(self_in, sw_in, constC, constD);
            flux_accum = flux_accum + flow_term;
          end 
          if(flux_accum < 0) flux_accum = { EXT_W{ 1'b0 } }; 
          cap_ext = { { EXT_W - DATA_W{ constB[DATA_W - 1] } }, constB };
          if(flux_accum > cap_ext) flux_accum = cap_ext; 
        end else begin
          friction_top = (unit_overflow_reverse_top)? unit_flux_reverse_top : { DATA_W{ 1'b0 } };
          friction_bottom = (unit_overflow_reverse_bottom)? unit_flux_reverse_bottom : { DATA_W{ 1'b0 } };
          friction_side = unit_pressure_gain;
          retain_val = fp_mul_const(self_in, unit_weight_retain);
          flux_accum = { { EXT_W - DATA_W{ retain_val[DATA_W - 1] } }, retain_val };
          flow_term = directional_flow(self_in, n_in, unit_weight_top, friction_top);
          flux_accum = flux_accum + flow_term;
          flow_term = directional_flow(self_in, s_in, unit_weight_bottom, friction_bottom);
          flux_accum = flux_accum + flow_term;
          flow_term = directional_flow(self_in, e_in, unit_weight_side, friction_side);
          flux_accum = flux_accum + flow_term;
          flow_term = directional_flow(self_in, w_in, unit_weight_side, friction_side);
          flux_accum = flux_accum + flow_term;
          if(diag_active) begin
            flow_term = directional_flow(self_in, ne_in, unit_weight_side, friction_side);
            flux_accum = flux_accum + flow_term;
            flow_term = directional_flow(self_in, nw_in, unit_weight_side, friction_side);
            flux_accum = flux_accum + flow_term;
            flow_term = directional_flow(self_in, se_in, unit_weight_side, friction_side);
            flux_accum = flux_accum + flow_term;
            flow_term = directional_flow(self_in, sw_in, unit_weight_side, friction_side);
            flux_accum = flux_accum + flow_term;
          end 
          prev_val = fp_mul_const(constB, unit_weight_prev);
          flux_accum = flux_accum + $signed({ { EXT_W - DATA_W{ prev_val[DATA_W - 1] } }, prev_val });
          if(flux_accum < $signed({ EXT_W{ 1'b0 } })) flux_accum = $signed({ EXT_W{ 1'b0 } }); 
          cap_ext = { { EXT_W - DATA_W{ 1'b0 } }, unit_flux_threshold };
          if(flux_accum > $signed(cap_ext)) flux_accum = $signed(cap_ext); 
        end
        alu_res = flux_accum[DATA_W-1:0];
      end
      5'd13: begin
        gain_sel = (unit_pressure_gain != { DATA_W{ 1'b0 } })? unit_pressure_gain : constA;
        iter_limit = (unit_pressure_iters < 8'd1)? 8'd1 : 
                     (unit_pressure_iters > 8'd8)? 8'd8 : unit_pressure_iters;
        pressure_val = self_in;
        for(iter=0; iter<iter_limit; iter=iter+1) begin
          delta_val = fp_sub(avg_nbrs, pressure_val);
          pressure_val = fp_add(pressure_val, fp_mul_const(delta_val, gain_sel));
        end
        alu_res = pressure_val;
      end
      5'd14: begin
        lr_sel = (unit_backprop_lr != { DATA_W{ 1'b0 } })? unit_backprop_lr : constA;
        neigh_sel = (unit_backprop_neigh != { DATA_W{ 1'b0 } })? unit_backprop_neigh : constC;
        decay_sel = (unit_backprop_decay != { DATA_W{ 1'b0 } })? unit_backprop_decay : constD;
        err = fp_sub(constB, self_in);
        grad_term = fp_mul_const(err, lr_sel);
        neigh_term = fp_mul_const(avg_nbrs, neigh_sel);
        decay_term = fp_mul_const(self_in, decay_sel);
        update_term = fp_sub(fp_add(grad_term, neigh_term), decay_term);
        alu_res = fp_add(self_in, update_term);
      end
      5'd15: alu_res = micro_val;
      5'd16: alu_res = laplacian;
      5'd17: begin
        lap_gain = fp_mul_const(laplacian, constA);
        sharpen_val = fp_sub(self_in, lap_gain);
        alu_res = sharpen_val;
      end
      5'd18: begin
        edge_mag = fp_add(dx_abs, dy_abs);
        alu_res = edge_mag;
      end
      5'd19: begin
        mix_self = fp_mul_const(self_in, constA);
        mix_avg = fp_mul_const(avg_nbrs, constB);
        mix_sum = fp_mul_const(sum_with_vert, constC);
        acc = fp_add(fp_add(mix_self, mix_avg), fp_add(mix_sum, constD));
        alu_res = acc;
      end
      default: alu_res = self_in;
    endcase
  end


  always @(posedge clk) begin
    if(rst) next_out <= { DATA_W{ 1'b0 } }; 
    else next_out <= alu_res;
  end


endmodule

