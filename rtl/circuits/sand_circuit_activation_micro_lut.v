`timescale 1ns/1ps

`include "sand_defs.vh"

// Microcode-based activation that mirrors the streaming processing element.
// Maps the signed input onto a 16-entry lookup table using coarse magnitude
// buckets plus a fractional bit to approximate smooth nonlinearities.
module sand_circuit_activation_micro_lut (
    input  signed [`DATA_W-1:0] value_in,
    input  wire   signed [`DATA_W-1:0] micro_lut [0:15],
    output signed [`DATA_W-1:0] value_out
);
    localparam integer Q_ONE = (1 << `FRAC_W);

    integer abs_val;
    reg [1:0] bucket;
    reg       frac_flag;
    reg [3:0] lut_idx;
    reg signed [`DATA_W-1:0] lut_val;

    always @* begin
        abs_val = value_in[`DATA_W-1] ? -$signed(value_in) : $signed(value_in);

        if (abs_val >= (Q_ONE << 1))
            bucket = 2'd3;
        else if (abs_val >= ((Q_ONE * 3) >> 1))
            bucket = 2'd2;
        else if (abs_val >= (Q_ONE >> 1))
            bucket = 2'd1;
        else
            bucket = 2'd0;

        if (`FRAC_W > 0)
            frac_flag = (abs_val >> (`FRAC_W - 1)) & 1'b1;
        else
            frac_flag = 1'b0;

        lut_idx = {value_in[`DATA_W-1], bucket, frac_flag};
        lut_val = micro_lut[lut_idx];
    end

    assign value_out = lut_val;
endmodule

