`timescale 1ns/1ps

`include "sand_defs.vh"
`include "sand_math.vh"

// Weighted blend of planar and vertical neighbors for behavioural demos.
module sand_circuit_neighbor_mix (
    input  signed [`DATA_W-1:0] self,
    input  signed [`DATA_W-1:0] north,
    input  signed [`DATA_W-1:0] south,
    input  signed [`DATA_W-1:0] east,
    input  signed [`DATA_W-1:0] west,
    input  signed [`DATA_W-1:0] above,
    input  signed [`DATA_W-1:0] below,
    input  signed [`DATA_W-1:0] self_gain_q,
    input  signed [`DATA_W-1:0] planar_gain_q,
    input  signed [`DATA_W-1:0] vertical_gain_q,
    input  signed [`DATA_W-1:0] bias_q,
    output signed [`DATA_W-1:0] mix_out
);
    localparam signed [`DATA_W-1:0] POS_MAX = (1 << (`DATA_W-1)) - 1;
    localparam signed [`DATA_W-1:0] NEG_MIN = -(1 << (`DATA_W-1));

    function automatic signed [`DATA_W-1:0] clamp_int;
        input integer value;
        begin
            if (value > POS_MAX)
                clamp_int = POS_MAX;
            else if (value < NEG_MIN)
                clamp_int = NEG_MIN;
            else
                clamp_int = value[`DATA_W-1:0];
        end
    endfunction

    function automatic signed [`DATA_W-1:0] fp_mul_q;
        input integer value;
        input integer gain;
        integer prod;
        integer rounder;
        begin
            prod = value * gain;
            if (`FRAC_W > 0) begin
                rounder = 1 << (`FRAC_W-1);
                if (prod >= 0)
                    prod = prod + rounder;
                else
                    prod = prod - rounder;
                prod = prod >>> `FRAC_W;
            end
            fp_mul_q = clamp_int(prod);
        end
    endfunction

    reg signed [`DATA_W-1:0] mix_reg;
    integer planar_sum;
    integer vertical_sum;
    integer planar_avg;
    integer vertical_avg;
    integer accum;
    integer temp;

    always @* begin
        planar_sum = $signed(north) + $signed(south) + $signed(east) + $signed(west);
        planar_avg = planar_sum >>> 2;
        vertical_sum = $signed(above) + $signed(below);
        vertical_avg = vertical_sum >>> 1;

        accum = fp_mul_q(self, self_gain_q);
        temp  = fp_mul_q(planar_avg, planar_gain_q);
        accum = accum + temp;
        accum = clamp_int(accum);

        temp  = fp_mul_q(vertical_avg, vertical_gain_q);
        accum = accum + temp;
        accum = clamp_int(accum);

        accum = accum + bias_q;
        mix_reg = clamp_int(accum);
    end

    assign mix_out = mix_reg;
endmodule
