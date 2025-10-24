// =============================================================================
// sand_pe.v — single "sand" processing element
// - Synchronous update: next_state depends on PREVIOUS tick neighbors
// - Avoids races via grid-level ping-pong buffers
// - Optional diagonals
// - Simple ALU with a microcode hook
// =============================================================================
`include "sand_defs.vh"
`include "sand_math.vh" //todo?

module sand_pe #(
    parameter DATA_W = `DATA_W,
    parameter FRAC_W = `FRAC_W
)(
    input  wire                   clk,
    input  wire                   rst,

    // Current cell & neighbors from the READ buffer (previous tick)
    input  wire [DATA_W-1:0]      self_in,
    input  wire [DATA_W-1:0]      n_in,
    input  wire [DATA_W-1:0]      s_in,
    input  wire [DATA_W-1:0]      e_in,
    input  wire [DATA_W-1:0]      w_in,
    input  wire [DATA_W-1:0]      ne_in,
    input  wire [DATA_W-1:0]      nw_in,
    input  wire [DATA_W-1:0]      se_in,
    input  wire [DATA_W-1:0]      sw_in,

    // Config
    input  wire [3:0]             opcode,
    input  wire                   use_diagonals, // 0 => 4-neigh, 1 => 8-neigh
    input  wire [DATA_W-1:0]      constA,
    input  wire [DATA_W-1:0]      constB,

    // Microcode table (16 entries x DATA_W), supplied by grid (shared ROM/RAM)
    input  wire [DATA_W-1:0]      micro_lut [0:15],

    // Output next state (to WRITE buffer)
    output reg  [DATA_W-1:0]      next_out
);

    // -------- Helper functions ------------------------------------------------
    function [DATA_W-1:0] fp_add;
        input [DATA_W-1:0] a,b; begin fp_add = a + b; end
    endfunction

    function [DATA_W-1:0] fp_sub;
        input [DATA_W-1:0] a,b; begin fp_sub = a - b; end
    endfunction

    function [DATA_W-1:0] fp_mul_const;
        input [DATA_W-1:0] a,c; begin
            // Q(FRAC_W) * Q(FRAC_W) >> FRAC_W (if c is fixed-point)
            fp_mul_const = (a * c) >>> FRAC_W;
        end
    endfunction

    function [DATA_W-1:0] fp_div_const;
        input [DATA_W-1:0] a,c; begin
            // a / c ~= (a << FRAC_W) / c (avoid divide-by-zero upstream)
            fp_div_const = (c == {DATA_W{1'b0}}) ? {DATA_W{1'b0}} : ((a <<< FRAC_W) / c);
        end
    endfunction

    // Sum / Average of neighbors (4 or 8)
    reg [DATA_W+3:0] sum_nbrs;   // headroom
    reg [DATA_W-1:0] avg_nbrs;
    reg [DATA_W-1:0] min_nbr, max_nbr;

    wire [DATA_W-1:0] nb4 [0:3];
    assign nb4[0]=n_in; assign nb4[1]=s_in; assign nb4[2]=e_in; assign nb4[3]=w_in;

    wire [DATA_W-1:0] nb8 [0:7];
    assign nb8[0]=n_in;  assign nb8[1]=s_in;  assign nb8[2]=e_in;  assign nb8[3]=w_in;
    assign nb8[4]=ne_in; assign nb8[5]=nw_in; assign nb8[6]=se_in; assign nb8[7]=sw_in;

    integer i;
    always @* begin
        sum_nbrs = { (DATA_W+4){1'b0} };
        min_nbr  = { DATA_W{1'b1} }; // max value
        max_nbr  = { DATA_W{1'b0} };

        if (!use_diagonals) begin
            for (i=0;i<4;i=i+1) begin
                sum_nbrs = sum_nbrs + nb4[i];
                if (nb4[i] < min_nbr) min_nbr = nb4[i];
                if (nb4[i] > max_nbr) max_nbr = nb4[i];
            end
            avg_nbrs = sum_nbrs[DATA_W-1:0] >> 2; // /4
        end else begin
            for (i=0;i<8;i=i+1) begin
                sum_nbrs = sum_nbrs + nb8[i];
                if (nb8[i] < min_nbr) min_nbr = nb8[i];
                if (nb8[i] > max_nbr) max_nbr = nb8[i];
            end
            avg_nbrs = sum_nbrs[DATA_W-1:0] >> 3; // /8
        end
    end

    // Microcode “indexer”: small, flexible hook.
    // You can redefine this to compose an index from bits of self/sum/avg/etc.
    wire [3:0] micro_idx = { opcode[1:0], self_in[1:0] }; // simple example
    wire [DATA_W-1:0] micro_val = micro_lut[micro_idx];

    // Main ALU
    reg [DATA_W-1:0] alu_res;
    always @* begin
        case (opcode)
            `OP_NOP:        alu_res = self_in;
            `OP_SELF:       alu_res = self_in;
            `OP_SUM_NBRS:   alu_res = sum_nbrs[DATA_W-1:0];
            `OP_AVG_NBRS:   alu_res = avg_nbrs;
            `OP_ADD_CONST:  alu_res = fp_add(self_in, constA);
            `OP_SUB_CONST:  alu_res = fp_sub(self_in, constA);
            `OP_MUL_CONST:  alu_res = fp_mul_const(self_in, constA);
            `OP_DIV_CONST:  alu_res = fp_div_const(self_in, constA);
            `OP_DIFFUSION:  begin
                // self + k*(avg - self)  where k = constA (0..1 in Q format)
                // diff = (avg - self)
                // k*diff = fp_mul_const(diff, constA)
                alu_res = fp_add(self_in, fp_mul_const(fp_sub(avg_nbrs, self_in), constA));
            end
            `OP_MIN:        alu_res = (self_in < min_nbr) ? self_in : min_nbr;
            `OP_MAX:        alu_res = (self_in > max_nbr) ? self_in : max_nbr;
            `OP_CLAMP:      alu_res = (self_in < constA) ? constA :
                                       (self_in > constB) ? constB : self_in;
            `OP_MICRO:      alu_res = micro_val;
            default:        alu_res = self_in;
        endcase
    end

    always @(posedge clk) begin
        if (rst) next_out <= {DATA_W{1'b0}};
        else     next_out <= alu_res;
    end

endmodule
