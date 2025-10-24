// Throughput: 1 cell/clk. Use a second read port or tiny line buffers to prefetch neighbors and raise throughput (e.g., 2–4 cells/clk) without changing the pointer‑swap idea.

`include "sand_defs.vh"
`include "sand_math.vh"

module sand_engine_raster #(
    parameter DATA_W = `DATA_W,
    parameter FRAC_W = `FRAC_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT
)(
    input  wire                   clk,
    input  wire                   rst,

    // Control
    input  wire                   start_frame,   // start one full grid step
    output reg                    busy,
    output reg                    frame_done,    // pulses when one step finishes

    // Config
    input  wire [3:0]             opcode,
    input  wire                   use_diagonals,
    input  wire [DATA_W-1:0]      constA,
    input  wire [DATA_W-1:0]      constB,
    input  wire [DATA_W-1:0]      micro_lut [0:15],

    // Jobmem2p interface
    output reg                    jm_we,
    output reg  [$clog2(`N_JOBS)-1:0] jm_job,
    output reg  [$clog2(`DEPTH)-1:0]  jm_layer,
    output reg                        jm_plane_sel,          // READ plane
    output reg                        jm_write_other_plane,  // WRITE to !plane
    output reg  [$clog2(WIDTH*HEIGHT)-1:0] jm_idx,
    output reg  [DATA_W-1:0]         jm_wdata,
    input  wire [DATA_W-1:0]         jm_rdata
);
    localparam CELLS = WIDTH*HEIGHT;

    // Raster counters
    reg [$clog2(WIDTH)-1:0]  x;
    reg [$clog2(HEIGHT)-1:0] y;

    // Neighbor fetch helper: compute linear indices with clamp
    function integer clamp;
        input integer v, lo, hi; begin
            if (v<lo) clamp=lo; else if (v>hi) clamp=hi; else clamp=v;
        end
    endfunction

    // State machine
    localparam S_IDLE=0, S_READ=1, S_ALU=2, S_WRITE=3, S_NEXT=4, S_DONE=5;
    reg [2:0] st;

    // Latches for neighbors
    reg [DATA_W-1:0] self_in, n_in, s_in, e_in, w_in, ne_in, nw_in, se_in, sw_in;

    // Microcode index (customize freely)
    wire [3:0] micro_idx = { opcode[1:0], self_in[1:0] };
    wire [DATA_W-1:0] micro_val = micro_lut[micro_idx];

    // ALU result
    reg [DATA_W-1:0] alu_res;

    // Sum/avg over 4/8 neighbors (simple rolling sum)
    reg [DATA_W+3:0] sum_n;
    reg [DATA_W-1:0] avg_n;
    reg [DATA_W-1:0] min_n, max_n;

    // Current job/layer programmed externally before start_frame via setters
    // Expose setters through a lightweight register interface (not shown here).

    // Simple public setters (drive before start):
    // jm_job, jm_layer, jm_plane_sel to choose the READ plane.

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; frame_done<=1'b0;
            x <= 0; y <= 0; jm_idx <= 0;
            jm_we <= 1'b0; jm_write_other_plane <= 1'b0;
        end else begin
            frame_done <= 1'b0; jm_we <= 1'b0; jm_write_other_plane <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (start_frame) begin
                        busy <= 1'b1;
                        x <= 0; y <= 0; jm_idx <= 0;
                        st <= S_READ;
                    end
                end
                S_READ: begin
                    // Schedule reads for self and neighbors (one per cycle each) —
                    // Here, for compactness, we reuse the single read port multiple cycles.
                    // In practice, give the wrapper a second read port or small line buffers.
                    integer xi, yi, idx;
                    // Self
                    xi = x; yi = y; idx = yi*WIDTH + xi; jm_idx <= idx;
                    self_in <= jm_rdata;
                    // N
                    xi = x; yi = clamp(y-1,0,HEIGHT-1); idx = yi*WIDTH + xi; jm_idx <= idx; n_in <= jm_rdata;
                    // S
                    xi = x; yi = clamp(y+1,0,HEIGHT-1); idx = yi*WIDTH + xi; jm_idx <= idx; s_in <= jm_rdata;
                    // E
                    xi = clamp(x+1,0,WIDTH-1); yi = y; idx = yi*WIDTH + xi; jm_idx <= idx; e_in <= jm_rdata;
                    // W
                    xi = clamp(x-1,0,WIDTH-1); yi = y; idx = yi*WIDTH + xi; jm_idx <= idx; w_in <= jm_rdata;
                    // Diagonals if used
                    if (use_diagonals) begin
                        xi = clamp(x+1,0,WIDTH-1); yi = clamp(y-1,0,HEIGHT-1); idx = yi*WIDTH + xi; jm_idx <= idx; ne_in <= jm_rdata;
                        xi = clamp(x-1,0,WIDTH-1); yi = clamp(y-1,0,HEIGHT-1); idx = yi*WIDTH + xi; jm_idx <= idx; nw_in <= jm_rdata;
                        xi = clamp(x+1,0,WIDTH-1); yi = clamp(y+1,0,HEIGHT-1); idx = yi*WIDTH + xi; jm_idx <= idx; se_in <= jm_rdata;
                        xi = clamp(x-1,0,WIDTH-1); yi = clamp(y+1,0,HEIGHT-1); idx = yi*WIDTH + xi; jm_idx <= idx; sw_in <= jm_rdata;
                    end else begin
                        ne_in <= self_in; nw_in <= self_in; se_in <= self_in; sw_in <= self_in; // unused
                    end
                    st <= S_ALU;
                end
                S_ALU: begin
                    // Reduce neighbors
                    integer i;
                    reg [DATA_W-1:0] list4 [0:3];
                    reg [DATA_W-1:0] list8 [0:7];
                    list4[0]=n_in; list4[1]=s_in; list4[2]=e_in; list4[3]=w_in;
                    list8[0]=n_in; list8[1]=s_in; list8[2]=e_in; list8[3]=w_in;
                    list8[4]=ne_in; list8[5]=nw_in; list8[6]=se_in; list8[7]=sw_in;
                    sum_n = { (DATA_W+4){1'b0} }; min_n = {DATA_W{1'b1}}; max_n = {DATA_W{1'b0}};
                    if (!use_diagonals) begin
                        for (i=0;i<4;i=i+1) begin
                            sum_n = sum_n + list4[i];
                            if (list4[i] < min_n) min_n = list4[i];
                            if (list4[i] > max_n) max_n = list4[i];
                        end
                        avg_n = sum_n[DATA_W-1:0] >> 2;
                    end else begin
                        for (i=0;i<8;i=i+1) begin
                            sum_n = sum_n + list8[i];
                            if (list8[i] < min_n) min_n = list8[i];
                            if (list8[i] > max_n) max_n = list8[i];
                        end
                        avg_n = sum_n[DATA_W-1:0] >> 3;
                    end

                    // ALU (uses saturating helpers)
                    case (opcode)
                        `OP_NOP, `OP_SELF: alu_res = self_in;
                        `OP_SUM_NBRS:      alu_res = sum_n[DATA_W-1:0];
                        `OP_AVG_NBRS:      alu_res = avg_n;
                        `OP_ADD_CONST:     alu_res = `FP_ADD(self_in,constA,DATA_W);
                        `OP_SUB_CONST:     alu_res = `FP_SUB(self_in,constA,DATA_W);
                        `OP_MUL_CONST:     alu_res = `FP_MUL_Q(self_in,constA,FRAC_W);
                        `OP_DIV_CONST:     alu_res = (constA==0) ? {DATA_W{1'b0}} : `FP_DIV_Q(self_in,constA,FRAC_W);
                        `OP_DIFFUSION:     alu_res = `FP_ADD(self_in, `FP_MUL_Q( (avg_n - self_in), constA, FRAC_W ), DATA_W);
                        `OP_MIN:           alu_res = (self_in < min_n) ? self_in : min_n;
                        `OP_MAX:           alu_res = (self_in > max_n) ? self_in : max_n;
                        `OP_CLAMP:         alu_res = (self_in < constA) ? constA : (self_in > constB ? constB : self_in);
                        `OP_MICRO:         alu_res = micro_val;
                        default:           alu_res = self_in;
                    endcase

                    st <= S_WRITE;
                end
                S_WRITE: begin
                    // Write into the opposite plane
                    jm_wdata <= alu_res;
                    jm_we <= 1'b1;
                    jm_write_other_plane <= 1'b1;
                    st <= S_NEXT;
                end
                S_NEXT: begin
                    // Advance raster
                    if (x == WIDTH-1) begin
                        x <= 0;
                        if (y == HEIGHT-1) begin
                            y <= 0; jm_idx <= 0; st <= S_DONE;
                        end else begin
                            y <= y + 1; jm_idx <= (y+1)*WIDTH;
                            st <= S_READ;
                        end
                    end else begin
                        x <= x + 1; jm_idx <= (y*WIDTH) + (x+1);
                        st <= S_READ;
                    end
                end
                S_DONE: begin
                    busy <= 1'b0; frame_done <= 1'b1; st <= S_IDLE;
                end
            endcase
        end
    end
endmodule