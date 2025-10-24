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
    input  wire [`OPCODE_W-1:0]      opcode,
    input  wire                      use_diagonals,
    input  wire [DATA_W-1:0]         constA,
    input  wire [DATA_W-1:0]         constB,
    input  wire [DATA_W-1:0]         constC,
    input  wire [DATA_W-1:0]         constD,
    input  wire [DATA_W-1:0]         micro_lut [0:15],
    input  wire                      micro_lut_we,
    input  wire [3:0]                micro_lut_waddr,
    input  wire [DATA_W-1:0]         micro_lut_wdata,

    // Scheduler supplied context (sampled on start_frame)
    input  wire [JOB_W-1:0]          job_id,
    input  wire [LAYER_W-1:0]        layer_id,
    input  wire                      plane_read_sel,
    input  wire                      unit_flux_enable,
    input  wire                      unit_overflow_reverse_top,
    input  wire                      unit_overflow_reverse_bottom,
    input  wire                      unit_pressure_diag_override,
    input  wire [7:0]                unit_pressure_iters,
    input  wire [DATA_W-1:0]         unit_weight_top,
    input  wire [DATA_W-1:0]         unit_weight_bottom,
    input  wire [DATA_W-1:0]         unit_weight_side,
    input  wire [DATA_W-1:0]         unit_weight_retain,
    input  wire [DATA_W-1:0]         unit_weight_prev,
    input  wire [DATA_W-1:0]         unit_flux_threshold,
    input  wire [DATA_W-1:0]         unit_flux_reverse_top,
    input  wire [DATA_W-1:0]         unit_flux_reverse_bottom,
    input  wire [DATA_W-1:0]         unit_pressure_gain,
    input  wire [DATA_W-1:0]         unit_backprop_lr,
    input  wire [DATA_W-1:0]         unit_backprop_neigh,
    input  wire [DATA_W-1:0]         unit_backprop_decay,
    input  wire [15:0]               unit_window_width,
    input  wire [15:0]               unit_window_height,
    input  wire [15:0]               unit_window_x_offset,
    input  wire [15:0]               unit_window_y_offset,

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
    localparam integer EXT_W = DATA_W + 4;

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
               S_DONE  = 3'd5,
               S_ALU_PRESS = 3'd6;

    reg [2:0]              st;
    reg [X_W-1:0]          cur_x;
    reg [Y_W-1:0]          cur_y;
    reg [3:0]              read_phase;
    reg                    diag_active;

    // Sampled config
    reg [`OPCODE_W-1:0]    opcode_reg;
    reg [DATA_W-1:0]       constA_reg, constB_reg, constC_reg, constD_reg;

    // Neighbor latches
    reg [DATA_W-1:0] self_in;
    reg [DATA_W-1:0] n_in, s_in, e_in, w_in;
    reg [DATA_W-1:0] ne_in, nw_in, se_in, sw_in;
    reg [DATA_W-1:0] above_in, below_in;

    // ALU plumbing
    reg [DATA_W-1:0] alu_res;
    reg              cell_changed;
    reg              unit_flux_enable_reg;
    reg              unit_overflow_reverse_top_reg;
    reg              unit_overflow_reverse_bottom_reg;
    reg [7:0]        unit_pressure_iters_reg;
    reg [DATA_W-1:0] unit_weight_top_reg;
    reg [DATA_W-1:0] unit_weight_bottom_reg;
    reg [DATA_W-1:0] unit_weight_side_reg;
    reg [DATA_W-1:0] unit_weight_retain_reg;
    reg [DATA_W-1:0] unit_weight_prev_reg;
    reg [DATA_W-1:0] unit_flux_threshold_reg;
    reg [DATA_W-1:0] unit_flux_reverse_top_reg;
    reg [DATA_W-1:0] unit_flux_reverse_bottom_reg;
    reg [DATA_W-1:0] unit_pressure_gain_reg;
    reg [DATA_W-1:0] unit_backprop_lr_reg;
    reg [DATA_W-1:0] unit_backprop_neigh_reg;
    reg [DATA_W-1:0] unit_backprop_decay_reg;

    // Dynamic window controls
    reg [X_W-1:0]    x_start_reg;
    reg [X_W-1:0]    x_end_reg;
    reg [Y_W-1:0]    y_start_reg;
    reg [Y_W-1:0]    y_end_reg;

    // Accumulators
    reg [31:0] activity_counter;
    reg [31:0] cycle_counter;

    // Layer helpers for Z-neighbors
    reg [LAYER_W-1:0] layer_reg;
    reg [LAYER_W-1:0] layer_above_reg;
    reg [LAYER_W-1:0] layer_below_reg;

    // Microcode storage + index
    reg  [DATA_W-1:0] micro_lut_reg [0:15];
    wire [3:0] micro_idx = { opcode_reg[1:0], self_in[1:0] };
    wire [DATA_W-1:0] micro_val = micro_lut_reg[micro_idx];

    wire signed [EXT_W-1:0] self_s   = {{(EXT_W-DATA_W){self_in[DATA_W-1]}}, self_in};
    wire signed [EXT_W-1:0] above_s  = {{(EXT_W-DATA_W){above_in[DATA_W-1]}}, above_in};
    wire signed [EXT_W-1:0] below_s  = {{(EXT_W-DATA_W){below_in[DATA_W-1]}}, below_in};
    wire signed [EXT_W-1:0] n_s      = {{(EXT_W-DATA_W){n_in[DATA_W-1]}}, n_in};
    wire signed [EXT_W-1:0] s_s      = {{(EXT_W-DATA_W){s_in[DATA_W-1]}}, s_in};
    wire signed [EXT_W-1:0] e_s      = {{(EXT_W-DATA_W){e_in[DATA_W-1]}}, e_in};
    wire signed [EXT_W-1:0] w_s      = {{(EXT_W-DATA_W){w_in[DATA_W-1]}}, w_in};

    wire signed [EXT_W-1:0] dx_signed = e_s - w_s;
    wire signed [EXT_W-1:0] dy_signed = s_s - n_s;
    wire [DATA_W-1:0]       dx_abs_val = (dx_signed[EXT_W-1]) ? (-dx_signed)[DATA_W-1:0] : dx_signed[DATA_W-1:0];
    wire [DATA_W-1:0]       dy_abs_val = (dy_signed[EXT_W-1]) ? (-dy_signed)[DATA_W-1:0] : dy_signed[DATA_W-1:0];

    wire signed [EXT_W-1:0] sum4_signed    = n_s + s_s + e_s + w_s;
    wire signed [EXT_W-1:0] sum3d_signed   = sum4_signed + above_s + below_s;
    wire signed [EXT_W-1:0] self_x4        = self_s <<< 2;
    wire signed [EXT_W-1:0] self_x2        = self_s <<< 1;
    wire signed [EXT_W-1:0] self_x6        = self_x4 + self_x2;
    wire signed [EXT_W-1:0] laplacian_signed = sum3d_signed - self_x6;
    wire [DATA_W-1:0]       laplacian_val  = laplacian_signed[DATA_W-1:0];

    // -------------------------------------------------------------------------
    // Sequential control
    // -------------------------------------------------------------------------
    integer xi, yi;
    integer mi;
    reg [DATA_W+3:0] sum_tmp;
    reg [DATA_W-1:0] avg_tmp;
    reg [DATA_W-1:0] min_tmp;
    reg [DATA_W-1:0] max_tmp;
    reg [DATA_W-1:0] avg_tmp_reg;
    reg [DATA_W-1:0] pressure_value;
    reg [7:0]        pressure_iters_rem;
    reg [DATA_W-1:0] sum_with_vert_tmp;

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
            constC_reg       <= {DATA_W{1'b0}};
            constD_reg       <= {DATA_W{1'b0}};
            activity_counter <= 32'd0;
            cycle_counter    <= 32'd0;
            unit_flux_enable_reg            <= 1'b0;
            unit_overflow_reverse_top_reg   <= 1'b0;
            unit_overflow_reverse_bottom_reg<= 1'b0;
            unit_pressure_iters_reg         <= 8'd1;
            unit_weight_top_reg             <= {DATA_W{1'b0}};
            unit_weight_bottom_reg          <= {DATA_W{1'b0}};
            unit_weight_side_reg            <= {DATA_W{1'b0}};
            unit_weight_retain_reg          <= {DATA_W{1'b0}};
            unit_weight_prev_reg            <= {DATA_W{1'b0}};
            unit_flux_threshold_reg         <= {DATA_W{1'b1}};
            unit_flux_reverse_top_reg       <= {DATA_W{1'b0}};
            unit_flux_reverse_bottom_reg    <= {DATA_W{1'b0}};
            unit_pressure_gain_reg          <= {DATA_W{1'b0}};
            unit_backprop_lr_reg            <= {DATA_W{1'b0}};
            unit_backprop_neigh_reg         <= {DATA_W{1'b0}};
            unit_backprop_decay_reg         <= {DATA_W{1'b0}};
            x_start_reg      <= {X_W{1'b0}};
            x_end_reg        <= (WIDTH > 0) ? WIDTH-1 : {X_W{1'b0}};
            y_start_reg      <= {Y_W{1'b0}};
            y_end_reg        <= (HEIGHT > 0) ? HEIGHT-1 : {Y_W{1'b0}};
            avg_tmp_reg      <= {DATA_W{1'b0}};
            pressure_value   <= {DATA_W{1'b0}};
            pressure_iters_rem <= 8'd0;
            above_in         <= {DATA_W{1'b0}};
            below_in         <= {DATA_W{1'b0}};
            layer_reg        <= {LAYER_W{1'b0}};
            layer_above_reg  <= {LAYER_W{1'b0}};
            layer_below_reg  <= {LAYER_W{1'b0}};
            for (mi=0; mi<16; mi=mi+1) micro_lut_reg[mi] <= {DATA_W{1'b0}};
        end else begin
            frame_done         <= 1'b0;
            jm_we              <= 1'b0;
            jm_write_other_plane <= 1'b0;

            if (start_frame) begin
                for (mi=0; mi<16; mi=mi+1) begin
                    micro_lut_reg[mi] <= micro_lut[mi];
                end
            end
            if (micro_lut_we) begin
                micro_lut_reg[micro_lut_waddr] <= micro_lut_wdata;
            end

            if (busy) cycle_counter <= cycle_counter + 1;

            case (st)
                S_IDLE: begin
                    if (start_frame) begin
                        integer width_tmp;
                        integer height_tmp;
                        integer x_off_tmp;
                        integer y_off_tmp;
                        integer x_end_tmp;
                        integer y_end_tmp;
                        integer width_max;
                        integer height_max;
                        busy           <= 1'b1;
                        cycle_counter  <= 32'd1;   // count current cycle
                        activity_counter <= 32'd0;
                        opcode_reg     <= opcode;
                        constA_reg     <= constA;
                        constB_reg     <= constB;
                        constC_reg     <= constC;
                        constD_reg     <= constD;
                        unit_flux_enable_reg            <= unit_flux_enable;
                        unit_overflow_reverse_top_reg   <= unit_overflow_reverse_top;
                        unit_overflow_reverse_bottom_reg<= unit_overflow_reverse_bottom;
                        unit_pressure_iters_reg         <= (unit_pressure_iters < 8'd1) ? 8'd1 :
                                                           (unit_pressure_iters > 8'd32) ? 8'd32 :
                                                           unit_pressure_iters;
                        unit_weight_top_reg             <= unit_weight_top;
                        unit_weight_bottom_reg          <= unit_weight_bottom;
                        unit_weight_side_reg            <= unit_weight_side;
                        unit_weight_retain_reg          <= unit_weight_retain;
                        unit_weight_prev_reg            <= unit_weight_prev;
                        unit_flux_threshold_reg         <= unit_flux_threshold;
                        unit_flux_reverse_top_reg       <= unit_flux_reverse_top;
                        unit_flux_reverse_bottom_reg    <= unit_flux_reverse_bottom;
                        unit_pressure_gain_reg          <= unit_pressure_gain;
                        unit_backprop_lr_reg            <= unit_backprop_lr;
                        unit_backprop_neigh_reg         <= unit_backprop_neigh;
                        unit_backprop_decay_reg         <= unit_backprop_decay;
                        diag_active    <= use_diagonals ||
                                           (unit_pressure_diag_override && (opcode == `OP_PRESSURE));
                        width_max  = WIDTH;
                        height_max = HEIGHT;
                        width_tmp  = (unit_window_width  == 16'd0) ? width_max  : unit_window_width;
                        height_tmp = (unit_window_height == 16'd0) ? height_max : unit_window_height;
                        if (width_tmp < 1)   width_tmp  = 1;
                        if (height_tmp < 1)  height_tmp = 1;
                        if (width_tmp > width_max)   width_tmp = width_max;
                        if (height_tmp > height_max) height_tmp = height_max;
                        x_off_tmp = unit_window_x_offset;
                        y_off_tmp = unit_window_y_offset;
                        if (x_off_tmp < 0) x_off_tmp = 0;
                        if (y_off_tmp < 0) y_off_tmp = 0;
                        if (x_off_tmp >= width_max)  x_off_tmp = (width_max > 0) ? (width_max - 1) : 0;
                        if (y_off_tmp >= height_max) y_off_tmp = (height_max > 0) ? (height_max - 1) : 0;
                        if ((x_off_tmp + width_tmp) > width_max) begin
                            width_tmp = width_max - x_off_tmp;
                            if (width_tmp < 1) width_tmp = 1;
                        end
                        if ((y_off_tmp + height_tmp) > height_max) begin
                            height_tmp = height_max - y_off_tmp;
                            if (height_tmp < 1) height_tmp = 1;
                        end
                        x_end_tmp = x_off_tmp + width_tmp - 1;
                        y_end_tmp = y_off_tmp + height_tmp - 1;
                        x_start_reg   <= x_off_tmp[X_W-1:0];
                        y_start_reg   <= y_off_tmp[Y_W-1:0];
                        x_end_reg     <= x_end_tmp[X_W-1:0];
                        y_end_reg     <= y_end_tmp[Y_W-1:0];
                        cur_x          <= x_off_tmp[X_W-1:0];
                        cur_y          <= y_off_tmp[Y_W-1:0];
                        read_phase     <= 4'd0;
                        jm_job         <= job_id;
                        jm_layer       <= layer_id;
                        layer_reg      <= layer_id;
                        if (DEPTH > 1) begin
                            layer_above_reg <= (layer_id == {LAYER_W{1'b0}}) ? layer_id : (layer_id - 1'b1);
                            layer_below_reg <= (layer_id == (DEPTH-1)) ? layer_id : (layer_id + 1'b1);
                        end else begin
                            layer_above_reg <= layer_id;
                            layer_below_reg <= layer_id;
                        end
                        jm_plane_sel   <= plane_read_sel;
                        jm_idx         <= idx_from_xy(x_off_tmp, y_off_tmp);
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
                                jm_layer <= layer_above_reg;
                                jm_idx   <= idx_from_xy(cur_x, cur_y);
                                read_phase <= 4'd10;
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
                            jm_layer   <= layer_above_reg;
                            jm_idx     <= idx_from_xy(cur_x, cur_y);
                            read_phase <= 4'd10;
                        end
                        4'd10: begin
                            above_in   <= jm_rdata;
                            jm_layer   <= layer_below_reg;
                            jm_idx     <= idx_from_xy(cur_x, cur_y);
                            read_phase <= 4'd11;
                        end
                        4'd11: begin
                            below_in   <= jm_rdata;
                            jm_layer   <= layer_reg;
                            jm_idx     <= idx_from_xy(cur_x, cur_y);
                            read_phase <= 4'd12;
                        end
                        4'd12: begin
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
                    sum_with_vert_tmp = `FP_ADD(`FP_ADD(sum_tmp[DATA_W-1:0], above_in, DATA_W),
                                                 below_in,
                                                 DATA_W);

                    if (opcode_reg == `OP_PRESSURE) begin
                        pressure_value     <= self_in;
                        avg_tmp_reg        <= avg_tmp;
                        pressure_iters_rem <= (unit_pressure_iters_reg < 8'd1) ? 8'd1
                                                : unit_pressure_iters_reg;
                        st <= S_ALU_PRESS;
                    end else begin
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
                            `OP_WATER_FLUX: begin
                                reg [DATA_W-1:0] flux_total;
                                reg [DATA_W-1:0] side_accum;
                                reg [DATA_W-1:0] diag_accum;
                                reg [DATA_W-1:0] overflow;
                                reg [DATA_W-1:0] reverse_top;
                                reg [DATA_W-1:0] reverse_bottom;
                                if (!unit_flux_enable_reg) begin
                                    flux_total = self_in;
                                end else begin
                                    flux_total = `FP_MUL_Q(self_in, unit_weight_retain_reg, FRAC_W);
                                    flux_total = `FP_ADD(flux_total,
                                                         `FP_MUL_Q(n_in, unit_weight_top_reg, FRAC_W),
                                                         DATA_W);
                                    flux_total = `FP_ADD(flux_total,
                                                         `FP_MUL_Q(s_in, unit_weight_bottom_reg, FRAC_W),
                                                         DATA_W);
                                    side_accum = `FP_ADD(e_in, w_in, DATA_W);
                                    if (diag_active) begin
                                        diag_accum = `FP_ADD(ne_in, nw_in, DATA_W);
                                        diag_accum = `FP_ADD(diag_accum, se_in, DATA_W);
                                        diag_accum = `FP_ADD(diag_accum, sw_in, DATA_W);
                                        side_accum = `FP_ADD(side_accum, diag_accum, DATA_W);
                                    end
                                    flux_total = `FP_ADD(flux_total,
                                                         `FP_MUL_Q(side_accum, unit_weight_side_reg, FRAC_W),
                                                         DATA_W);
                                    flux_total = `FP_ADD(flux_total,
                                                         `FP_MUL_Q(constB_reg, unit_weight_prev_reg, FRAC_W),
                                                         DATA_W);
                                    if (flux_total > unit_flux_threshold_reg) begin
                                        overflow = `FP_SUB(flux_total, unit_flux_threshold_reg, DATA_W);
                                        flux_total = unit_flux_threshold_reg;
                                        if (unit_overflow_reverse_top_reg) begin
                                            reverse_top = `FP_MUL_Q(overflow, unit_flux_reverse_top_reg, FRAC_W);
                                            flux_total  = `FP_SUB(flux_total, reverse_top, DATA_W);
                                        end
                                        if (unit_overflow_reverse_bottom_reg) begin
                                            reverse_bottom = `FP_MUL_Q(overflow, unit_flux_reverse_bottom_reg, FRAC_W);
                                            flux_total     = `FP_SUB(flux_total, reverse_bottom, DATA_W);
                                        end
                                    end
                                end
                                alu_res = flux_total;
                            end
                            `OP_BACKPROP: begin
                                reg [DATA_W-1:0] err_term;
                                reg [DATA_W-1:0] grad_term;
                                reg [DATA_W-1:0] neigh_term;
                                reg [DATA_W-1:0] decay_term;
                                reg [DATA_W-1:0] update_term;
                                err_term    = `FP_SUB(constB_reg, self_in, DATA_W);
                                grad_term   = `FP_MUL_Q(err_term, unit_backprop_lr_reg, FRAC_W);
                                neigh_term  = `FP_MUL_Q(avg_tmp, unit_backprop_neigh_reg, FRAC_W);
                                decay_term  = `FP_MUL_Q(self_in, unit_backprop_decay_reg, FRAC_W);
                                update_term = `FP_SUB(`FP_ADD(grad_term, neigh_term, DATA_W),
                                                      decay_term,
                                                      DATA_W);
                                alu_res     = `FP_ADD(self_in, update_term, DATA_W);
                            end
                            `OP_MICRO:    alu_res = micro_val;
                            `OP_LAPLACIAN: alu_res = laplacian_val;
                            `OP_SHARPEN: begin
                                reg [DATA_W-1:0] lap_gain;
                                reg [DATA_W-1:0] sharpen_val;
                                lap_gain    = `FP_MUL_Q(laplacian_val, constA_reg, FRAC_W);
                                sharpen_val = `FP_SUB(self_in, lap_gain, DATA_W);
                                alu_res     = sharpen_val;
                            end
                            `OP_EDGE: begin
                                reg [DATA_W-1:0] edge_mag;
                                edge_mag = `FP_ADD(dx_abs_val, dy_abs_val, DATA_W);
                                alu_res  = edge_mag;
                            end
                            `OP_MIX: begin
                                reg [DATA_W-1:0] mix_self;
                                reg [DATA_W-1:0] mix_avg;
                                reg [DATA_W-1:0] mix_sum;
                                reg [DATA_W-1:0] mix_bias;
                                reg [DATA_W-1:0] acc0;
                                reg [DATA_W-1:0] acc1;
                                mix_self = `FP_MUL_Q(self_in, constA_reg, FRAC_W);
                                mix_avg  = `FP_MUL_Q(avg_tmp, constB_reg, FRAC_W);
                                mix_sum  = `FP_MUL_Q(sum_with_vert_tmp, constC_reg, FRAC_W);
                                mix_bias = constD_reg;
                                acc0     = `FP_ADD(mix_self, mix_avg, DATA_W);
                                acc1     = `FP_ADD(mix_sum, mix_bias, DATA_W);
                                alu_res  = `FP_ADD(acc0, acc1, DATA_W);
                            end
                            default:      alu_res = self_in;
                        endcase

                        cell_changed <= (alu_res != self_in);
                        st           <= S_WRITE;
                    end
                end

                S_ALU_PRESS: begin
                    reg [DATA_W-1:0] delta;
                    reg [DATA_W-1:0] next_pressure;
                    delta         = `FP_SUB(avg_tmp_reg, pressure_value, DATA_W);
                    next_pressure = `FP_ADD(pressure_value,
                                             `FP_MUL_Q(delta, unit_pressure_gain_reg, FRAC_W),
                                             DATA_W);
                    pressure_value <= next_pressure;
                    if (pressure_iters_rem <= 8'd1) begin
                        alu_res      <= next_pressure;
                        cell_changed <= (next_pressure != self_in);
                        st           <= S_WRITE;
                    end else begin
                        pressure_iters_rem <= pressure_iters_rem - 1'b1;
                    end
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
                    if (cur_x == x_end_reg) begin
                        cur_x <= x_start_reg;
                        if (cur_y == y_end_reg) begin
                            cur_y <= y_start_reg;
                            st    <= S_DONE;
                        end else begin
                            cur_y <= cur_y + 1'b1;
                            jm_idx <= idx_from_xy(x_start_reg, cur_y + 1'b1);
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
