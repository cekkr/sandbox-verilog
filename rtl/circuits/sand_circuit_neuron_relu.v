// =============================================================================
// sand_circuit_neuron_relu.v — Weighted edge/raw combiner with ReLU + fire flag
// =============================================================================
//
// This small combinational block fuses two Q-format inputs (edge magnitude and
// raw intensity) with programmable gains, bias, and threshold.  It mirrors the
// behavioural logic used in the Sand examples so Python/YAML driven harnesses
// can stitch neurons together without rewriting Verilog each time.
//
// Inputs and outputs are signed fixed-point values matching `DATA_W` and
// `FRAC_W` from `sand_defs.vh`.
// =============================================================================

`timescale 1ns/1ps

`include "sand_defs.vh"

module sand_circuit_neuron_relu #(
    parameter integer DATA_W = `DATA_W,
    parameter integer FRAC_W = `FRAC_W
) (
    input  signed [DATA_W-1:0] edge_in,
    input  signed [DATA_W-1:0] raw_in,
    input  signed [DATA_W-1:0] edge_gain_q,
    input  signed [DATA_W-1:0] raw_gain_q,
    input  signed [DATA_W-1:0] bias_q,
    input  signed [DATA_W-1:0] threshold_q,
    output reg signed [DATA_W-1:0] raw_out,
    output reg signed [DATA_W-1:0] relu_out,
    output reg                    fire
);
    localparam integer Q_MAX = (1 << (DATA_W - 1)) - 1;
    localparam integer Q_MIN = -(1 << (DATA_W - 1));

    integer edge_term;
    integer raw_term;
    integer combined;

    function integer clamp_signed;
        input integer value;
        begin
            if (value > Q_MAX)
                clamp_signed = Q_MAX;
            else if (value < Q_MIN)
                clamp_signed = Q_MIN;
            else
                clamp_signed = value;
        end
    endfunction

    function integer clamp_positive;
        input integer value;
        begin
            if (value < 0)
                clamp_positive = 0;
            else if (value > Q_MAX)
                clamp_positive = Q_MAX;
            else
                clamp_positive = value;
        end
    endfunction

    always @* begin
        edge_term = (edge_gain_q * edge_in) >>> FRAC_W;
        raw_term  = (raw_gain_q * raw_in) >>> FRAC_W;
        combined  = edge_term + raw_term + bias_q;

        raw_out  = clamp_signed(combined);

        if (combined > 0)
            relu_out = clamp_positive(combined);
        else
            relu_out = 0;

        fire = (combined >= threshold_q);
    end
endmodule
