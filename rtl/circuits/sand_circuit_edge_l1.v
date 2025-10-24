// =============================================================================
// sand_circuit_edge_l1.v — L1 edge magnitude slice (|E-W| + |S-N|)
// Part of the reusable Sand example circuit library.
//
// The module is combinational and intended to be instantiated by behavioural
// harnesses or higher-level generators.  It keeps the arithmetic aligned with
// the project-wide fixed-point conventions exposed through `sand_defs.vh`.
// =============================================================================

`timescale 1ns/1ps

`include "sand_defs.vh"

module sand_circuit_edge_l1 #(
    parameter DATA_W = `DATA_W
) (
    center,
    north,
    south,
    east,
    west,
    edge
);
    input  [DATA_W-1:0] center;
    input  [DATA_W-1:0] north;
    input  [DATA_W-1:0] south;
    input  [DATA_W-1:0] east;
    input  [DATA_W-1:0] west;
    output reg [DATA_W-1:0] edge;

    localparam integer Q_MAX = (1 << (DATA_W - 1)) - 1;

    integer dx;
    integer dy;
    integer abs_dx;
    integer abs_dy;
    integer sum;

    always @* begin
        dx = east - west;
        if (dx < 0)
            abs_dx = -dx;
        else
            abs_dx = dx;

        dy = south - north;
        if (dy < 0)
            abs_dy = -dy;
        else
            abs_dy = dy;

        sum = abs_dx + abs_dy;
        if (sum < 0)
            sum = 0;
        else if (sum > Q_MAX)
            sum = Q_MAX;

        edge = sum;
    end
endmodule
