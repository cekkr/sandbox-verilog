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
    input  wire [DATA_W-1:0]      above_in,
    input  wire [DATA_W-1:0]      below_in,

    // Config
    input  wire [`OPCODE_W-1:0]   opcode,
    input  wire                   use_diagonals, // 0 => 4-neigh, 1 => 8-neigh
    input  wire [DATA_W-1:0]      constA,
    input  wire [DATA_W-1:0]      constB,
    input  wire [DATA_W-1:0]      constC,
    input  wire [DATA_W-1:0]      constD,

    // Microcode table (16 entries x DATA_W), supplied by grid (shared ROM/RAM)
    input  wire [DATA_W-1:0]      micro_lut [0:15],

    // Output next state (to WRITE buffer)
    output reg  [DATA_W-1:0]      next_out
);
    localparam integer EXT_W = DATA_W + 4;

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
    reg [DATA_W+2:0] sum4_only;

    wire [DATA_W-1:0] nb4 [0:3];
    assign nb4[0]=n_in; assign nb4[1]=s_in; assign nb4[2]=e_in; assign nb4[3]=w_in;

    wire [DATA_W-1:0] nb8 [0:7];
    assign nb8[0]=n_in;  assign nb8[1]=s_in;  assign nb8[2]=e_in;  assign nb8[3]=w_in;
    assign nb8[4]=ne_in; assign nb8[5]=nw_in; assign nb8[6]=se_in; assign nb8[7]=sw_in;

    integer i;
    always @* begin
        sum_nbrs = { (DATA_W+4){1'b0} };
        sum4_only = {(DATA_W+3){1'b0}};
        min_nbr  = { DATA_W{1'b1} }; // max value
        max_nbr  = { DATA_W{1'b0} };

        for (i=0;i<4;i=i+1) begin
            sum4_only = sum4_only + nb4[i];
            if (nb4[i] < min_nbr) min_nbr = nb4[i];
            if (nb4[i] > max_nbr) max_nbr = nb4[i];
        end

        if (!use_diagonals) begin
            sum_nbrs = {1'b0, sum4_only};
            avg_nbrs = sum4_only[DATA_W-1:0] >> 2; // /4
        end else begin
            sum_nbrs = {1'b0, sum4_only};
            for (i=4;i<8;i=i+1) begin
                sum_nbrs = sum_nbrs + nb8[i];
                if (nb8[i] < min_nbr) min_nbr = nb8[i];
                if (nb8[i] > max_nbr) max_nbr = nb8[i];
            end
            avg_nbrs = sum_nbrs[DATA_W-1:0] >> 3; // /8
        end

        if (above_in < min_nbr) min_nbr = above_in;
        if (above_in > max_nbr) max_nbr = above_in;
        if (below_in < min_nbr) min_nbr = below_in;
        if (below_in > max_nbr) max_nbr = below_in;
    end

    // Microcode “indexer”: small, flexible hook.
    // You can redefine this to compose an index from bits of self/sum/avg/etc.
    wire [3:0] micro_idx = { opcode[1:0], self_in[1:0] }; // simple example
    wire [DATA_W-1:0] micro_val = micro_lut[micro_idx];

    // Signed helper views
    wire signed [EXT_W-1:0] self_s  = {{(EXT_W-DATA_W){self_in[DATA_W-1]}}, self_in};
    wire signed [EXT_W-1:0] above_s = {{(EXT_W-DATA_W){above_in[DATA_W-1]}}, above_in};
    wire signed [EXT_W-1:0] below_s = {{(EXT_W-DATA_W){below_in[DATA_W-1]}}, below_in};
    wire signed [EXT_W-1:0] n_s     = {{(EXT_W-DATA_W){n_in[DATA_W-1]}}, n_in};
    wire signed [EXT_W-1:0] s_s     = {{(EXT_W-DATA_W){s_in[DATA_W-1]}}, s_in};
    wire signed [EXT_W-1:0] e_s     = {{(EXT_W-DATA_W){e_in[DATA_W-1]}}, e_in};
    wire signed [EXT_W-1:0] w_s     = {{(EXT_W-DATA_W){w_in[DATA_W-1]}}, w_in};

    wire signed [EXT_W-1:0] dx_signed = e_s - w_s;
    wire signed [EXT_W-1:0] dy_signed = s_s - n_s;
    wire [DATA_W-1:0]       dx_abs = (dx_signed[EXT_W-1]) ? (-dx_signed)[DATA_W-1:0] : dx_signed[DATA_W-1:0];
    wire [DATA_W-1:0]       dy_abs = (dy_signed[EXT_W-1]) ? (-dy_signed)[DATA_W-1:0] : dy_signed[DATA_W-1:0];

    wire signed [EXT_W-1:0] sum4_signed = n_s + s_s + e_s + w_s;
    wire signed [EXT_W-1:0] sum3d_signed = sum4_signed + above_s + below_s;
    wire signed [EXT_W-1:0] self_x4 = self_s <<< 2;
    wire signed [EXT_W-1:0] self_x2 = self_s <<< 1;
    wire signed [EXT_W-1:0] self_x6 = self_x4 + self_x2;
    wire signed [EXT_W-1:0] laplacian_signed = sum3d_signed - self_x6;
    wire [DATA_W-1:0]       laplacian = laplacian_signed[DATA_W-1:0];

    wire [DATA_W-1:0] sum_planar      = sum_nbrs[DATA_W-1:0];
    wire [DATA_W-1:0] sum_with_vert   = fp_add(fp_add(sum_planar, above_in), below_in);

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
            `OP_WATER_FLUX: begin
                reg [DATA_W-1:0] flux_total;
                reg [DATA_W-1:0] overflow;
                flux_total = fp_add(fp_mul_const(self_in, constA), sum_nbrs[DATA_W-1:0]);
                if (flux_total > constB) begin
                    overflow   = fp_sub(flux_total, constB);
                    flux_total = fp_sub(flux_total, overflow);
                end
                alu_res = flux_total;
            end
            `OP_PRESSURE: begin
                reg [DATA_W-1:0] delta;
                delta   = fp_sub(avg_nbrs, self_in);
                alu_res = fp_add(self_in, fp_mul_const(delta, constA));
            end
            `OP_BACKPROP: begin
                reg [DATA_W-1:0] err;
                err     = fp_sub(constB, self_in);
                alu_res = fp_add(self_in, fp_mul_const(err, constA));
            end
            `OP_MICRO:      alu_res = micro_val;
            `OP_LAPLACIAN:  alu_res = laplacian;
            `OP_SHARPEN: begin
                reg [DATA_W-1:0] lap_gain;
                reg [DATA_W-1:0] sharpen_val;
                lap_gain    = fp_mul_const(laplacian, constA);
                sharpen_val = fp_sub(self_in, lap_gain);
                alu_res     = sharpen_val;
            end
            `OP_EDGE: begin
                reg [DATA_W-1:0] edge_mag;
                edge_mag = fp_add(dx_abs, dy_abs);
                alu_res  = edge_mag;
            end
            `OP_MIX: begin
                reg [DATA_W-1:0] mix_self;
                reg [DATA_W-1:0] mix_avg;
                reg [DATA_W-1:0] mix_sum;
                reg [DATA_W-1:0] acc;
                mix_self = fp_mul_const(self_in, constA);
                mix_avg  = fp_mul_const(avg_nbrs, constB);
                mix_sum  = fp_mul_const(sum_with_vert, constC);
                acc      = fp_add(fp_add(mix_self, mix_avg), fp_add(mix_sum, constD));
                alu_res  = acc;
            end
            default:        alu_res = self_in;
        endcase
    end

    always @(posedge clk) begin
        if (rst) next_out <= {DATA_W{1'b0}};
        else     next_out <= alu_res;
    end

endmodule
