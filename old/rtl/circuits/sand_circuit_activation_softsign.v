`timescale 1ns/1ps

`include "sand_defs.vh"

// Preface: better without it: in a sandbox the pressure of a grain unit is related to neighborhood
// if a pressure it's excessive, the sandbox is simply broken. A softsign is useful to avoid this case
// but brokes the complex flux concept. So could be used ad "grain explosion" checker.

// Smooth, saturating activation based on the softsign function.
module sand_circuit_activation_softsign (
    input  signed [`DATA_W-1:0] value_in,
    output signed [`DATA_W-1:0] value_out
);
    localparam integer Q_ONE_INT = (1 << `FRAC_W);
    localparam signed [`DATA_W-1:0] Q_MAX = (1 << (`DATA_W-1)) - 1;
    localparam signed [`DATA_W-1:0] Q_MIN = -(1 << (`DATA_W-1));

    integer numerator;
    integer denominator;
    integer abs_val;
    integer scaled;
    reg signed [`DATA_W-1:0] result;

    always @* begin
        numerator = $signed(value_in);
        abs_val = value_in[`DATA_W-1] ? -$signed(value_in) : $signed(value_in);
        denominator = abs_val + Q_ONE_INT;
        if (denominator <= 0)
            denominator = 1;

        scaled = (numerator <<< `FRAC_W);
        if (scaled >= 0)
            scaled = scaled + (denominator >> 1);
        else
            scaled = scaled - (denominator >> 1);

        result = $signed(scaled / denominator);

        if (result > Q_MAX)
            result = Q_MAX;
        else if (result < Q_MIN)
            result = Q_MIN;
    end

    assign value_out = result;
endmodule
