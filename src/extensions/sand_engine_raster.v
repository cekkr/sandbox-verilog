// =============================================================================
// sand_engine_raster.v — single-ported raster update engine with pointer swap
// - Streams one cell at a time through a micro-coded ALU
// - Designed to pair with sand_jobmem2p (two-plane job memory)
// - Provides activity and cycle metrics for adaptive scheduling
// =============================================================================
`include "sand_defs.vh"
`include "sand_math.vh"

module sand_engine_raster #(
    parameter DATA_W = `DATA_W,
    parameter FRAC_W = `FRAC_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT,
    parameter N_JOBS = `N_JOBS,
    parameter DEPTH  = `DEPTH,
    parameter JOB_W  = (N_JOBS > 1) ? $clog2(N_JOBS) : 1,
    parameter LAYER_W= (DEPTH  > 1) ? $clog2(DEPTH)  : 1,
    parameter CELL_W = ((WIDTH*HEIGHT) > 1) ? $clog2(WIDTH*HEIGHT) : 1
)(
    input  wire                      clk,
    input  wire                      rst,

    // Control
    input  wire                      start_frame,   // pulse to start one grid update
    output reg                       busy,
    output reg                       frame_done,    // pulse when frame completes

    // Config (sampled on start_frame)
    input  wire [3:0]                opcode,
    input  wire                      use_diagonals,
    input  wire [DATA_W-1:0]         constA,
    input  wire [DATA_W-1:0]         constB,
    input  wire [DATA_W-1:0]         micro_lut [0:15],

    // Scheduler supplied context (sampled on start_frame)
    input  wire [JOB_W-1:0]          job_id,
    input  wire [LAYER_W-1:0]        layer_id,
    input  wire                      plane_read_sel,

    // Job memory interface (two-plane BRAM wrapper)
    output reg                       jm_we,
    output reg  [JOB_W-1:0]          jm_job,
    output reg  [LAYER_W-1:0]        jm_layer,
    output reg                       jm_plane_sel,          // READ plane
    output reg                       jm_write_other_plane,  // assert when writing WRITE plane
    output reg  [CELL_W-1:0]         jm_idx,
    output reg  [DATA_W-1:0]         jm_wdata,
    input  wire [DATA_W-1:0]         jm_rdata,

    // Telemetry
    output reg  [31:0]               frame_activity,        // cells that changed
    output reg  [31:0]               frame_cycles           // cycles spent between start/done
);
    localparam integer CELLS = WIDTH*HEIGHT;
    localparam integer X_W   = (WIDTH  > 1) ? $clog2(WIDTH)  : 1;
    localparam integer Y_W   = (HEIGHT > 1) ? $clog2(HEIGHT) : 1;

    // -------------------------------------------------------------------------
    // Helper functions
    // -------------------------------------------------------------------------
    function integer clamp_int;
        input integer v;
        input integer lo;
        input integer hi;
        begin
            if (v < lo) clamp_int = lo;
            else if (v > hi) clamp_int = hi;
            else clamp_int = v;
        end
    endfunction

    function [CELL_W-1:0] idx_from_xy;
        input integer xi;
        input integer yi;
        begin
            idx_from_xy = yi*WIDTH + xi;
        end
    endfunction

    function [DATA_W-1:0] min2;
        input [DATA_W-1:0] a, b;
        begin
            min2 = (a < b) ? a : b;
        end
    endfunction

    function [DATA_W-1:0] max2;
        input [DATA_W-1:0] a, b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Internal state
    // -------------------------------------------------------------------------
    localparam S_IDLE  = 3'd0,
               S_READ  = 3'd1,
               S_ALU   = 3'd2,
               S_WRITE = 3'd3,
               S_NEXT  = 3'd4,
               S_DONE  = 3'd5;

    reg [2:0]              st;
    reg [X_W-1:0]          cur_x;
    reg [Y_W-1:0]          cur_y;
    reg [3:0]              read_phase;
    reg                    diag_active;

    // Sampled config
    reg [3:0]              opcode_reg;
    reg [DATA_W-1:0]       constA_reg, constB_reg;

    // Neighbor latches
    reg [DATA_W-1:0] self_in;
    reg [DATA_W-1:0] n_in, s_in, e_in, w_in;
    reg [DATA_W-1:0] ne_in, nw_in, se_in, sw_in;

    // ALU plumbing
    reg [DATA_W-1:0] alu_res;
    reg              cell_changed;

    // Accumulators
    reg [31:0] activity_counter;
    reg [31:0] cycle_counter;

    // Microcode index
    wire [3:0] micro_idx = { opcode_reg[1:0], self_in[1:0] };
    wire [DATA_W-1:0] micro_val = micro_lut[micro_idx];

    // -------------------------------------------------------------------------
    // Sequential control
    // -------------------------------------------------------------------------
    integer xi, yi;
    reg [DATA_W+3:0] sum_tmp;
    reg [DATA_W-1:0] avg_tmp;
    reg [DATA_W-1:0] min_tmp;
    reg [DATA_W-1:0] max_tmp;

    always @(posedge clk) begin
        if (rst) begin
            st               <= S_IDLE;
            busy             <= 1'b0;
            frame_done       <= 1'b0;
            frame_activity   <= 32'd0;
            frame_cycles     <= 32'd0;
            jm_we            <= 1'b0;
            jm_idx           <= {CELL_W{1'b0}};
            jm_wdata         <= {DATA_W{1'b0}};
            jm_plane_sel     <= 1'b0;
            jm_job           <= {JOB_W{1'b0}};
            jm_layer         <= {LAYER_W{1'b0}};
            jm_write_other_plane <= 1'b0;
            cur_x            <= {X_W{1'b0}};
            cur_y            <= {Y_W{1'b0}};
            read_phase       <= 4'd0;
            diag_active      <= 1'b0;
            opcode_reg       <= `OP_NOP;
            constA_reg       <= {DATA_W{1'b0}};
            constB_reg       <= {DATA_W{1'b0}};
            activity_counter <= 32'd0;
            cycle_counter    <= 32'd0;
        end else begin
            frame_done         <= 1'b0;
            jm_we              <= 1'b0;
            jm_write_other_plane <= 1'b0;

            if (busy) cycle_counter <= cycle_counter + 1;

            case (st)
                S_IDLE: begin
                    if (start_frame) begin
                        busy           <= 1'b1;
                        cycle_counter  <= 32'd1;   // count current cycle
                        activity_counter <= 32'd0;
                        cur_x          <= {X_W{1'b0}};
                        cur_y          <= {Y_W{1'b0}};
                        read_phase     <= 4'd0;
                        diag_active    <= use_diagonals;
                        opcode_reg     <= opcode;
                        constA_reg     <= constA;
                        constB_reg     <= constB;
                        jm_job         <= job_id;
                        jm_layer       <= layer_id;
                        jm_plane_sel   <= plane_read_sel;
                        jm_idx         <= idx_from_xy(0,0);
                        busy           <= 1'b1;
                        st             <= S_READ;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_READ: begin
                    case (read_phase)
                        4'd0: begin
                            read_phase <= 4'd1;
                            // address already issued (jm_idx)
                        end
                        4'd1: begin
                            self_in     <= jm_rdata;
                            xi          = cur_x;
                            yi          = clamp_int(cur_y-1, 0, HEIGHT-1);
                            jm_idx      <= idx_from_xy(xi, yi);
                            read_phase  <= 4'd2;
                        end
                        4'd2: begin
                            n_in        <= jm_rdata;
                            xi          = cur_x;
                            yi          = clamp_int(cur_y+1, 0, HEIGHT-1);
                            jm_idx      <= idx_from_xy(xi, yi);
                            read_phase  <= 4'd3;
                        end
                        4'd3: begin
                            s_in        <= jm_rdata;
                            xi          = clamp_int(cur_x+1, 0, WIDTH-1);
                            yi          = cur_y;
                            jm_idx      <= idx_from_xy(xi, yi);
                            read_phase  <= 4'd4;
                        end
                        4'd4: begin
                            e_in        <= jm_rdata;
                            xi          = clamp_int(cur_x-1, 0, WIDTH-1);
                            yi          = cur_y;
                            jm_idx      <= idx_from_xy(xi, yi);
                            read_phase  <= 4'd5;
                        end
                        4'd5: begin
                            w_in        <= jm_rdata;
                            if (diag_active) begin
                                xi     = clamp_int(cur_x+1, 0, WIDTH-1);
                                yi     = clamp_int(cur_y-1, 0, HEIGHT-1);
                                jm_idx <= idx_from_xy(xi, yi);
                                read_phase <= 4'd6;
                            end else begin
                                ne_in <= self_in;
                                nw_in <= self_in;
                                se_in <= self_in;
                                sw_in <= self_in;
                                read_phase <= 4'd15;
                            end
                        end
                        4'd6: begin
                            ne_in      <= jm_rdata;
                            xi         = clamp_int(cur_x-1, 0, WIDTH-1);
                            yi         = clamp_int(cur_y-1, 0, HEIGHT-1);
                            jm_idx     <= idx_from_xy(xi, yi);
                            read_phase <= 4'd7;
                        end
                        4'd7: begin
                            nw_in      <= jm_rdata;
                            xi         = clamp_int(cur_x+1, 0, WIDTH-1);
                            yi         = clamp_int(cur_y+1, 0, HEIGHT-1);
                            jm_idx     <= idx_from_xy(xi, yi);
                            read_phase <= 4'd8;
                        end
                        4'd8: begin
                            se_in      <= jm_rdata;
                            xi         = clamp_int(cur_x-1, 0, WIDTH-1);
                            yi         = clamp_int(cur_y+1, 0, HEIGHT-1);
                            jm_idx     <= idx_from_xy(xi, yi);
                            read_phase <= 4'd9;
                        end
                        4'd9: begin
                            sw_in      <= jm_rdata;
                            read_phase <= 4'd15;
                        end
                        4'd15: begin
                            read_phase <= 4'd0;
                            st         <= S_ALU;
                        end
                        default: read_phase <= 4'd0;
                    endcase
                end

                S_ALU: begin
                    // Sum/avg/min/max
                    sum_tmp = { {(DATA_W+4){1'b0}} };
                    sum_tmp = n_in + s_in + e_in + w_in;
                    min_tmp = min2(min2(n_in, s_in), min2(e_in, w_in));
                    max_tmp = max2(max2(n_in, s_in), max2(e_in, w_in));
                    if (diag_active) begin
                        sum_tmp = sum_tmp + ne_in + nw_in + se_in + sw_in;
                        min_tmp = min2(min_tmp, min2(ne_in, nw_in));
                        min_tmp = min2(min_tmp, min2(se_in, sw_in));
                        max_tmp = max2(max_tmp, max2(ne_in, nw_in));
                        max_tmp = max2(max_tmp, max2(se_in, sw_in));
                        avg_tmp = sum_tmp[DATA_W-1:0] >> 3;
                    end else begin
                        avg_tmp = sum_tmp[DATA_W-1:0] >> 2;
                    end

                    case (opcode_reg)
                        `OP_NOP,
                        `OP_SELF:    alu_res = self_in;
                        `OP_SUM_NBRS:alu_res = sum_tmp[DATA_W-1:0];
                        `OP_AVG_NBRS:alu_res = avg_tmp;
                        `OP_ADD_CONST: alu_res = `FP_ADD(self_in, constA_reg, DATA_W);
                        `OP_SUB_CONST: alu_res = `FP_SUB(self_in, constA_reg, DATA_W);
                        `OP_MUL_CONST: alu_res = `FP_MUL_Q(self_in, constA_reg, FRAC_W);
                        `OP_DIV_CONST: alu_res = (constA_reg=={DATA_W{1'b0}}) ? {DATA_W{1'b0}}
                                                     : `FP_DIV_Q(self_in, constA_reg, FRAC_W);
                        `OP_DIFFUSION: begin
                            reg [DATA_W-1:0] diff;
                            diff    = `FP_SUB(avg_tmp, self_in, DATA_W);
                            alu_res = `FP_ADD(self_in, `FP_MUL_Q(diff, constA_reg, FRAC_W), DATA_W);
                        end
                        `OP_MIN:      alu_res = (self_in < min_tmp) ? self_in : min_tmp;
                        `OP_MAX:      alu_res = (self_in > max_tmp) ? self_in : max_tmp;
                        `OP_CLAMP:    alu_res = (self_in < constA_reg) ? constA_reg :
                                                (self_in > constB_reg) ? constB_reg : self_in;
                        `OP_MICRO:    alu_res = micro_val;
                        default:      alu_res = self_in;
                    endcase

                    cell_changed <= (alu_res != self_in);
                    st           <= S_WRITE;
                end

                S_WRITE: begin
                    jm_idx               <= idx_from_xy(cur_x, cur_y);
                    jm_wdata             <= alu_res;
                    jm_we                <= 1'b1;
                    jm_write_other_plane <= 1'b1;
                    if (cell_changed) activity_counter <= activity_counter + 1;
                    st <= S_NEXT;
                end

                S_NEXT: begin
                    if (cur_x == (WIDTH-1)) begin
                        cur_x <= {X_W{1'b0}};
                        if (cur_y == (HEIGHT-1)) begin
                            cur_y <= {Y_W{1'b0}};
                            st    <= S_DONE;
                        end else begin
                            cur_y <= cur_y + 1'b1;
                            jm_idx <= idx_from_xy(0, cur_y + 1'b1);
                            st    <= S_READ;
                        end
                    end else begin
                        cur_x <= cur_x + 1'b1;
                        jm_idx <= idx_from_xy(cur_x + 1'b1, cur_y);
                        st    <= S_READ;
                    end
                end

                S_DONE: begin
                    busy           <= 1'b0;
                    frame_done     <= 1'b1;
                    frame_activity <= activity_counter;
                    frame_cycles   <= cycle_counter + 1;
                    activity_counter <= 32'd0;
                    cycle_counter  <= 32'd0;
                    st             <= S_IDLE;
                end
            endcase
        end
    end
endmodule
