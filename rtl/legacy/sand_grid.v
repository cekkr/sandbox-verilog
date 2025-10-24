// =============================================================================
// sand_grid.v — fully parallel grid of PEs with ping-pong buffers
// - Parameterized WIDTH x HEIGHT x (optional) DEPTH processed one layer at a time
// - Two frame buffers (READ/WRITE) per active job context (selected externally)
// - Boundary handling: replicate edges (customize as needed)
// =============================================================================
`include "sand_defs.vh"

module sand_grid #(
    parameter DATA_W = `DATA_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT
)(
    input  wire                   clk,
    input  wire                   rst,

    // One layer per invocation (external engine iterates through DEPTH)
    // READ buffer (previous state) for current layer
    input  wire [DATA_W-1:0]      read_buf [0:HEIGHT-1][0:WIDTH-1],
    // WRITE buffer (next state) output for current layer
    output wire [DATA_W-1:0]      write_buf[0:HEIGHT-1][0:WIDTH-1],

    // Config (broadcast)
    input  wire [`OPCODE_W-1:0]   opcode,
    input  wire                   use_diagonals,
    input  wire [DATA_W-1:0]      constA,
    input  wire [DATA_W-1:0]      constB,
    input  wire [DATA_W-1:0]      constC,
    input  wire [DATA_W-1:0]      constD,
    input  wire [DATA_W-1:0]      micro_lut [0:15]
);
    genvar y,x;

    // Helper: clamp indices to edges (replicate)
    function integer clamp;
        input integer v, lo, hi;
        begin
            if (v < lo) clamp = lo;
            else if (v > hi) clamp = hi;
            else clamp = v;
        end
    endfunction

    generate
        for (y=0; y<HEIGHT; y=y+1) begin: ROW
            for (x=0; x<WIDTH; x=x+1) begin: COL
                // Gather neighbors (with edge replication)
                wire [DATA_W-1:0] self_in = read_buf[y][x];
                wire [DATA_W-1:0] n_in  = read_buf[clamp(y-1,0,HEIGHT-1)][x];
                wire [DATA_W-1:0] s_in  = read_buf[clamp(y+1,0,HEIGHT-1)][x];
                wire [DATA_W-1:0] e_in  = read_buf[y][clamp(x+1,0,WIDTH-1)];
                wire [DATA_W-1:0] w_in  = read_buf[y][clamp(x-1,0,WIDTH-1)];
                wire [DATA_W-1:0] ne_in = read_buf[clamp(y-1,0,HEIGHT-1)][clamp(x+1,0,WIDTH-1)];
                wire [DATA_W-1:0] nw_in = read_buf[clamp(y-1,0,HEIGHT-1)][clamp(x-1,0,WIDTH-1)];
                wire [DATA_W-1:0] se_in = read_buf[clamp(y+1,0,HEIGHT-1)][clamp(x+1,0,WIDTH-1)];
                wire [DATA_W-1:0] sw_in = read_buf[clamp(y+1,0,HEIGHT-1)][clamp(x-1,0,WIDTH-1)];
                wire [DATA_W-1:0] above_in = self_in;
                wire [DATA_W-1:0] below_in = self_in;

                sand_pe #(
                    .DATA_W(DATA_W),
                    .FRAC_W(`FRAC_W)
                ) u_pe (
                    .clk(clk),
                    .rst(rst),
                    .self_in(self_in),
                    .n_in(n_in), .s_in(s_in), .e_in(e_in), .w_in(w_in),
                    .ne_in(ne_in), .nw_in(nw_in), .se_in(se_in), .sw_in(sw_in),
                    .above_in(above_in), .below_in(below_in),
                    .opcode(opcode),
                    .use_diagonals(use_diagonals),
                    .constA(constA),
                    .constB(constB),
                    .constC(constC),
                    .constD(constD),
                    .micro_lut(micro_lut),
                    .next_out(write_buf[y][x])
                );
            end
        end
    endgenerate

endmodule
