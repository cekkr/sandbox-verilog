// =============================================================================
// sand_scheduler_dynamic.v — adaptive scheduler with pointer-swap raster engine
// - Bridges CSR control to the streaming engine and two-plane job memory
// - Dynamically adjusts per-job step budgets based on activity & cycle metrics
// =============================================================================
`include "sand_defs.vh"

module sand_scheduler_dynamic #(
    parameter DATA_W = `DATA_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT,
    parameter DEPTH  = `DEPTH,
    parameter N_JOBS = `N_JOBS
)(
    input  wire                      clk,
    input  wire                      rst,

    // Tiny CSR bus
    input  wire                      csr_we,
    input  wire [7:0]                csr_addr,
    input  wire [31:0]               csr_wdata,
    input  wire                      csr_re,
    output reg  [31:0]               csr_rdata,

    // Seeding port (writes plane 0 by default)
    input  wire                      seed_we,
    input  wire [((N_JOBS > 1) ? $clog2(N_JOBS) : 1)-1:0] seed_job,
    input  wire [((DEPTH  > 1) ? $clog2(DEPTH)  : 1)-1:0] seed_layer,
    input  wire [(((WIDTH*HEIGHT) > 1) ? $clog2(WIDTH*HEIGHT) : 1)-1:0] seed_idx,
    input  wire [DATA_W-1:0]         seed_data,

    output reg  [N_JOBS-1:0]         job_done
);
    localparam integer CELLS   = WIDTH*HEIGHT;
    localparam integer JOB_W   = (N_JOBS > 1) ? $clog2(N_JOBS) : 1;
    localparam integer LAYER_W = (DEPTH  > 1) ? $clog2(DEPTH)  : 1;
    localparam integer CELL_W  = (CELLS  > 1) ? $clog2(CELLS)  : 1;
    localparam integer STEP_MAX= (`STEPS_PER_SLICE > 0) ? `STEPS_PER_SLICE : 1;

    // -------------------------------------------------------------------------
    // Configuration registers
    // -------------------------------------------------------------------------
    reg [`OPCODE_W-1:0]  opcode;
    reg [DATA_W-1:0]     constA, constB, constC, constD;
    reg                  force_diag, use_micro;
    reg [DATA_W-1:0]     micro_lut [0:15];
    reg                  micro_lut_wr_stb;
    reg [3:0]            micro_lut_wr_idx;
    reg [DATA_W-1:0]     micro_lut_wr_data;

    // Enhanced unit behaviour controls
    reg                  unit_flux_enable;
    reg                  unit_overflow_reverse_top;
    reg                  unit_overflow_reverse_bottom;
    reg                  unit_pressure_diag_override;
    reg [7:0]            unit_pressure_iters;
    reg [DATA_W-1:0]     unit_weight_top;
    reg [DATA_W-1:0]     unit_weight_bottom;
    reg [DATA_W-1:0]     unit_weight_side;
    reg [DATA_W-1:0]     unit_weight_retain;
    reg [DATA_W-1:0]     unit_weight_prev;
    reg [DATA_W-1:0]     unit_flux_threshold;
    reg [DATA_W-1:0]     unit_flux_reverse_top;
    reg [DATA_W-1:0]     unit_flux_reverse_bottom;
    reg [DATA_W-1:0]     unit_pressure_gain;
    reg [DATA_W-1:0]     unit_backprop_lr;
    reg [DATA_W-1:0]     unit_backprop_neigh;
    reg [DATA_W-1:0]     unit_backprop_decay;

    // Per-job dynamic window placement
    reg [15:0]           unit_window_width  [0:N_JOBS-1];
    reg [15:0]           unit_window_height [0:N_JOBS-1];
    reg [15:0]           unit_window_xoff   [0:N_JOBS-1];
    reg [15:0]           unit_window_yoff   [0:N_JOBS-1];

    // Adaptive control registers
    reg                  adapt_enable;
    reg                  adapt_auto;
    reg                  adapt_use_heavy;
    reg [7:0]            adapt_manual_steps;
    reg [7:0]            adapt_min_steps;
    reg [7:0]            adapt_max_steps;
    reg [31:0]           adapt_thresh_lo;
    reg [31:0]           adapt_thresh_hi;
    reg [31:0]           adapt_cycle_limit;
    reg [JOB_W-1:0]      status_job_sel;

    // Per-job adaptive state
    reg [7:0]            step_budget [0:N_JOBS-1];
    reg [31:0]           last_activity [0:N_JOBS-1];
    reg [31:0]           last_cycles   [0:N_JOBS-1];

    // Plane select per job/layer
    reg [DEPTH-1:0]      plane_sel [0:N_JOBS-1];

    // -------------------------------------------------------------------------
    // Memory + engine wiring
    // -------------------------------------------------------------------------
    wire                       jm_we_i;
    wire [JOB_W-1:0]           jm_job_i;
    wire [LAYER_W-1:0]         jm_layer_i;
    wire                       jm_plane_sel_i;
    wire                       jm_write_other_plane_i;
    wire [CELL_W-1:0]          jm_idx_i;
    wire [DATA_W-1:0]          jm_wdata_i;
    wire [DATA_W-1:0]          jm_rdata_i;

    sand_jobmem2p #(
        .DATA_W(DATA_W),
        .WIDTH(WIDTH),
        .HEIGHT(HEIGHT),
        .DEPTH(DEPTH),
        .N_JOBS(N_JOBS)
    ) u_mem (
        .clk(clk),
        .seed_we(seed_we),
        .seed_job(seed_job),
        .seed_layer(seed_layer),
        .seed_plane(1'b0),
        .seed_idx(seed_idx),
        .seed_data(seed_data),
        .eng_we(jm_we_i),
        .eng_job(jm_job_i),
        .eng_layer(jm_layer_i),
        .eng_plane_sel(jm_plane_sel_i),
        .eng_write_other_plane(jm_write_other_plane_i),
        .eng_idx(jm_idx_i),
        .eng_wdata(jm_wdata_i),
        .eng_rdata(jm_rdata_i)
    );

    reg                      start_frame;
    wire                     eng_busy;
    wire                     eng_done;
    reg  [JOB_W-1:0]         eng_job_sel;
    reg  [LAYER_W-1:0]       eng_layer_sel;
    reg                      eng_plane_sel;
    wire [31:0]              eng_activity;
    wire [31:0]              eng_cycles;
    reg  [15:0]              win_width_sel;
    reg  [15:0]              win_height_sel;
    reg  [15:0]              win_xoff_sel;
    reg  [15:0]              win_yoff_sel;

    sand_engine_raster #(
        .DATA_W(DATA_W),
        .FRAC_W(`FRAC_W),
        .WIDTH(WIDTH),
        .HEIGHT(HEIGHT),
        .N_JOBS(N_JOBS),
        .DEPTH(DEPTH)
    ) u_eng (
        .clk(clk),
        .rst(rst),
        .start_frame(start_frame),
        .busy(eng_busy),
        .frame_done(eng_done),
        .opcode(use_micro ? `OP_MICRO : opcode),
        .use_diagonals(force_diag),
        .constA(constA),
        .constB(constB),
        .constC(constC),
        .constD(constD),
        .micro_lut(micro_lut),
        .micro_lut_we(micro_lut_wr_stb),
        .micro_lut_waddr(micro_lut_wr_idx),
        .micro_lut_wdata(micro_lut_wr_data),
        .job_id(eng_job_sel),
        .layer_id(eng_layer_sel),
        .plane_read_sel(eng_plane_sel),
        .jm_we(jm_we_i),
        .jm_job(jm_job_i),
        .jm_layer(jm_layer_i),
        .jm_plane_sel(jm_plane_sel_i),
        .jm_write_other_plane(jm_write_other_plane_i),
        .jm_idx(jm_idx_i),
        .jm_wdata(jm_wdata_i),
        .jm_rdata(jm_rdata_i),
        .frame_activity(eng_activity),
        .frame_cycles(eng_cycles),
        .unit_flux_enable(unit_flux_enable),
        .unit_overflow_reverse_top(unit_overflow_reverse_top),
        .unit_overflow_reverse_bottom(unit_overflow_reverse_bottom),
        .unit_pressure_diag_override(unit_pressure_diag_override),
        .unit_pressure_iters(unit_pressure_iters),
        .unit_weight_top(unit_weight_top),
        .unit_weight_bottom(unit_weight_bottom),
        .unit_weight_side(unit_weight_side),
        .unit_weight_retain(unit_weight_retain),
        .unit_weight_prev(unit_weight_prev),
        .unit_flux_threshold(unit_flux_threshold),
        .unit_flux_reverse_top(unit_flux_reverse_top),
        .unit_flux_reverse_bottom(unit_flux_reverse_bottom),
        .unit_pressure_gain(unit_pressure_gain),
        .unit_backprop_lr(unit_backprop_lr),
        .unit_backprop_neigh(unit_backprop_neigh),
        .unit_backprop_decay(unit_backprop_decay),
        .unit_window_width(win_width_sel),
        .unit_window_height(win_height_sel),
        .unit_window_x_offset(win_xoff_sel),
        .unit_window_y_offset(win_yoff_sel)
    );

    // -------------------------------------------------------------------------
    // Scheduler FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE  = 3'd0,
               S_WAIT  = 3'd1,
               S_NEXTJ = 3'd2,
               S_NEXTL = 3'd3;

    reg [2:0]          st;
    reg [JOB_W-1:0]    cur_job;
    reg [LAYER_W-1:0]  cur_layer;
    reg [7:0]          cur_budget;
    reg [7:0]          step_cnt;

    wire [JOB_W-1:0]   next_job = (cur_job == (N_JOBS-1)) ? {JOB_W{1'b0}} : (cur_job + 1'b1);

    // -------------------------------------------------------------------------
    // Helper functions/tasks
    // -------------------------------------------------------------------------
    function [7:0] clamp_steps;
        input [15:0] value;
        integer tmp;
        begin
            tmp = value;
            if (tmp < 1) tmp = 1;
            if (tmp > STEP_MAX) tmp = STEP_MAX;
            clamp_steps = tmp[7:0];
        end
    endfunction

    wire [7:0] step_max_u8 = clamp_steps(STEP_MAX);

    wire heavy_opcode = (opcode == `OP_MUL_CONST) ||
                        (opcode == `OP_DIV_CONST) ||
                        (opcode == `OP_DIFFUSION) ||
                        (opcode == `OP_MICRO) ||
                        (opcode == `OP_SHARPEN) ||
                        (opcode == `OP_MIX);

    // -------------------------------------------------------------------------
    // CSR write path + scheduler core
    // -------------------------------------------------------------------------
    integer j, l;
    reg [7:0] adapt_min_clamped;
    reg [7:0] adapt_max_clamped;
    reg [7:0] manual_clamped;

    always @(posedge clk) begin
        if (rst) begin
            opcode        <= `OP_DIFFUSION;
            constA        <= {DATA_W{1'b0}};
            constB        <= {DATA_W{1'b0}};
            constC        <= {DATA_W{1'b0}};
            constD        <= {DATA_W{1'b0}};
            force_diag    <= (`USE_DIAGONALS != 0);
            use_micro     <= 1'b0;
            adapt_enable  <= 1'b0;
            adapt_auto    <= 1'b1;
            adapt_use_heavy <= 1'b1;
            unit_flux_enable            <= 1'b0;
            unit_overflow_reverse_top   <= 1'b0;
            unit_overflow_reverse_bottom<= 1'b0;
            unit_pressure_diag_override <= 1'b0;
            unit_pressure_iters         <= 8'd1;
            unit_weight_top             <= {DATA_W{1'b0}};
            unit_weight_bottom          <= {DATA_W{1'b0}};
            unit_weight_side            <= {DATA_W{1'b0}};
            unit_weight_retain          <= {DATA_W{1'b0}};
            unit_weight_prev            <= {DATA_W{1'b0}};
            unit_flux_threshold         <= {DATA_W{1'b1}};
            unit_flux_reverse_top       <= {DATA_W{1'b0}};
            unit_flux_reverse_bottom    <= {DATA_W{1'b0}};
            unit_pressure_gain          <= {DATA_W{1'b0}};
            unit_backprop_lr            <= {DATA_W{1'b0}};
            unit_backprop_neigh         <= {DATA_W{1'b0}};
            unit_backprop_decay         <= {DATA_W{1'b0}};
            adapt_manual_steps <= clamp_steps(`ADAPT_DEFAULT_MANUAL_STEPS);
            adapt_min_steps    <= clamp_steps(`ADAPT_DEFAULT_MIN_STEPS);
            adapt_max_steps    <= clamp_steps(`ADAPT_DEFAULT_MAX_STEPS);
            adapt_thresh_lo    <= `ADAPT_DEFAULT_LOW_THRESH;
            adapt_thresh_hi    <= `ADAPT_DEFAULT_HIGH_THRESH;
            adapt_cycle_limit  <= `ADAPT_DEFAULT_CAP_CYCLES;
            status_job_sel     <= {JOB_W{1'b0}};
            micro_lut_wr_stb   <= 1'b0;
            micro_lut_wr_idx   <= 4'd0;
            micro_lut_wr_data  <= {DATA_W{1'b0}};

            for (j=0; j<16; j=j+1) micro_lut[j] <= {DATA_W{1'b0}};
            for (j=0; j<N_JOBS; j=j+1) begin
                step_budget[j]   <= clamp_steps(`STEPS_PER_SLICE);
                last_activity[j] <= 32'd0;
                last_cycles[j]   <= 32'd0;
                unit_window_width[j]  <= WIDTH;
                unit_window_height[j] <= HEIGHT;
                unit_window_xoff[j]   <= 16'd0;
                unit_window_yoff[j]   <= 16'd0;
                for (l=0; l<DEPTH; l=l+1) plane_sel[j][l] <= 1'b0;
            end

            st          <= S_IDLE;
            cur_job     <= {JOB_W{1'b0}};
            cur_layer   <= {LAYER_W{1'b0}};
            cur_budget  <= clamp_steps(`STEPS_PER_SLICE);
            step_cnt    <= 8'd0;
            start_frame <= 1'b0;
            job_done    <= {N_JOBS{1'b0}};
            eng_job_sel   <= {JOB_W{1'b0}};
            eng_layer_sel <= {LAYER_W{1'b0}};
            eng_plane_sel <= 1'b0;
            win_width_sel  <= WIDTH;
            win_height_sel <= HEIGHT;
            win_xoff_sel   <= 16'd0;
            win_yoff_sel   <= 16'd0;
        end else begin
            start_frame <= 1'b0;
            micro_lut_wr_stb <= 1'b0;

            // ---------------- CSR writes -------------------------------------
            if (csr_we) begin
                case (csr_addr)
                    `CSR_JOB_SELECT: begin
                        status_job_sel <= csr_wdata[JOB_W-1:0];
                    end
                    `CSR_RULE_OP:     opcode     <= csr_wdata[`OPCODE_W-1:0];
                    `CSR_RULE_CONSTA: constA     <= csr_wdata[DATA_W-1:0];
                    `CSR_RULE_CONSTB: constB     <= csr_wdata[DATA_W-1:0];
                    `CSR_RULE_CONSTC: constC     <= csr_wdata[DATA_W-1:0];
                    `CSR_RULE_CONSTD: constD     <= csr_wdata[DATA_W-1:0];
                    `CSR_FLAGS: begin
                        force_diag <= csr_wdata[0];
                        use_micro  <= csr_wdata[1];
                    end
                    `CSR_STATUS: begin
                        job_done <= job_done & ~csr_wdata[N_JOBS-1:0];
                    end
                    `CSR_ADAPT_CTRL: begin
                        adapt_enable      <= csr_wdata[0];
                        adapt_auto        <= csr_wdata[1];
                        adapt_use_heavy   <= csr_wdata[2];
                        manual_clamped    <= clamp_steps({8'd0, ((csr_wdata >> 3)  & 8'hFF)});
                        adapt_min_clamped <= clamp_steps({8'd0, ((csr_wdata >> 11) & 8'hFF)});
                        adapt_max_clamped <= clamp_steps({8'd0, ((csr_wdata >> 19) & 8'hFF)});
                        if (adapt_max_clamped < adapt_min_clamped)
                            adapt_max_clamped <= adapt_min_clamped;
                        adapt_manual_steps <= manual_clamped;
                        adapt_min_steps    <= adapt_min_clamped;
                        adapt_max_steps    <= adapt_max_clamped;
                    end
                    `CSR_ADAPT_THRESH_LO: adapt_thresh_lo <= csr_wdata;
                    `CSR_ADAPT_THRESH_HI: adapt_thresh_hi <= csr_wdata;
                    `CSR_ADAPT_CAPACITY:  adapt_cycle_limit <= csr_wdata;
                    `CSR_ADAPT_STATUS_SEL: status_job_sel <= csr_wdata[JOB_W-1:0];
                    `CSR_UNIT_CTRL: begin
                        unit_flux_enable            <= csr_wdata[0];
                        unit_overflow_reverse_top   <= csr_wdata[1];
                        unit_overflow_reverse_bottom<= csr_wdata[2];
                        unit_pressure_diag_override <= csr_wdata[3];
                        if (csr_wdata[15:8] == 8'd0)
                            unit_pressure_iters <= 8'd1;
                        else if (csr_wdata[15:8] > 8'd32)
                            unit_pressure_iters <= 8'd32;
                        else
                            unit_pressure_iters <= csr_wdata[15:8];
                    end
                    `CSR_UNIT_WINDOW_WH: begin
                        integer idx;
                        integer width_tmp;
                        integer height_tmp;
                        integer x_tmp;
                        integer y_tmp;
                        idx = status_job_sel;
                        if (idx < N_JOBS) begin
                            width_tmp  = csr_wdata[15:0];
                            height_tmp = csr_wdata[31:16];
                            if (width_tmp == 0)  width_tmp  = WIDTH;
                            if (height_tmp == 0) height_tmp = HEIGHT;
                            if (width_tmp < 1)   width_tmp = 1;
                            if (height_tmp < 1)  height_tmp = 1;
                            if (width_tmp > WIDTH)   width_tmp = WIDTH;
                            if (height_tmp > HEIGHT) height_tmp = HEIGHT;
                            x_tmp = unit_window_xoff[idx];
                            y_tmp = unit_window_yoff[idx];
                            if ((x_tmp + width_tmp) > WIDTH)
                                width_tmp = WIDTH - x_tmp;
                            if ((y_tmp + height_tmp) > HEIGHT)
                                height_tmp = HEIGHT - y_tmp;
                            if (width_tmp < 1)  width_tmp = 1;
                            if (height_tmp < 1) height_tmp = 1;
                            unit_window_width[idx]  <= width_tmp[15:0];
                            unit_window_height[idx] <= height_tmp[15:0];
                        end
                    end
                    `CSR_UNIT_WINDOW_OFFSET: begin
                        integer idx;
                        integer x_tmp;
                        integer y_tmp;
                        integer width_tmp;
                        integer height_tmp;
                        idx = status_job_sel;
                        if (idx < N_JOBS) begin
                            x_tmp = csr_wdata[15:0];
                            y_tmp = csr_wdata[31:16];
                            if (x_tmp < 0) x_tmp = 0;
                            if (y_tmp < 0) y_tmp = 0;
                            if (x_tmp >= WIDTH)  x_tmp = WIDTH - 1;
                            if (y_tmp >= HEIGHT) y_tmp = HEIGHT - 1;
                            width_tmp  = unit_window_width[idx];
                            height_tmp = unit_window_height[idx];
                            if ((x_tmp + width_tmp) > WIDTH) begin
                                width_tmp = WIDTH - x_tmp;
                                if (width_tmp < 1) width_tmp = 1;
                            end
                            if ((y_tmp + height_tmp) > HEIGHT) begin
                                height_tmp = HEIGHT - y_tmp;
                                if (height_tmp < 1) height_tmp = 1;
                            end
                            unit_window_xoff[idx]   <= x_tmp[15:0];
                            unit_window_yoff[idx]   <= y_tmp[15:0];
                            unit_window_width[idx]  <= width_tmp[15:0];
                            unit_window_height[idx] <= height_tmp[15:0];
                        end
                    end
                    `CSR_UNIT_FLUX_WEIGHT_TOP:     unit_weight_top    <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_WEIGHT_BOTTOM:  unit_weight_bottom <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_WEIGHT_SIDE:    unit_weight_side   <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_WEIGHT_RETAIN:  unit_weight_retain <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_WEIGHT_PREV:    unit_weight_prev   <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_THRESHOLD:      unit_flux_threshold     <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_REVERSE_TOP:    unit_flux_reverse_top   <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_FLUX_REVERSE_BOTTOM: unit_flux_reverse_bottom<= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_PRESSURE_GAIN:       unit_pressure_gain  <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_BACKPROP_LR:         unit_backprop_lr     <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_BACKPROP_NEIGH:      unit_backprop_neigh  <= csr_wdata[DATA_W-1:0];
                    `CSR_UNIT_BACKPROP_DECAY:      unit_backprop_decay  <= csr_wdata[DATA_W-1:0];
                    default: begin
                        if (csr_addr >= `CSR_MICRO_BASE && csr_addr < (`CSR_MICRO_BASE+16)) begin
                            micro_lut[csr_addr-`CSR_MICRO_BASE] <= csr_wdata[DATA_W-1:0];
                            micro_lut_wr_stb  <= 1'b1;
                            micro_lut_wr_idx  <= csr_addr-`CSR_MICRO_BASE;
                            micro_lut_wr_data <= csr_wdata[DATA_W-1:0];
                        end
                    end
                endcase
            end

            // ---------------- Scheduler FSM ---------------------------------
            case (st)
                S_IDLE: begin
                    cur_budget    <= step_budget[cur_job];
                    eng_job_sel   <= cur_job;
                    eng_layer_sel <= cur_layer;
                    eng_plane_sel <= plane_sel[cur_job][cur_layer];
                    win_width_sel  <= unit_window_width[cur_job];
                    win_height_sel <= unit_window_height[cur_job];
                    win_xoff_sel   <= unit_window_xoff[cur_job];
                    win_yoff_sel   <= unit_window_yoff[cur_job];
                    start_frame   <= 1'b1;
                    st            <= S_WAIT;
                end

                S_WAIT: begin
                    if (eng_done) begin
                        reg plane_next;
                        reg [7:0] budget_curr;
                        reg [7:0] budget_next;
                        reg [7:0] min_step;
                        reg [7:0] max_step;
                        reg [7:0] manual_step;
                        reg [31:0] act_lo;
                        reg [31:0] act_hi;
                        reg [7:0] step_cnt_inc;

                        plane_next = plane_sel[cur_job][cur_layer] ^ 1'b1;
                        plane_sel[cur_job][cur_layer] <= plane_next;

                        last_activity[cur_job] <= eng_activity;
                        last_cycles[cur_job]   <= eng_cycles;

                        budget_curr = step_budget[cur_job];
                        min_step    <= adapt_min_steps;
                        max_step    <= adapt_max_steps;
                        manual_step <= adapt_manual_steps;
                        if (min_step < 1) min_step = 1;
                        if (max_step < min_step) max_step = min_step;
                        if (max_step > step_max_u8) max_step = step_max_u8;
                        if (manual_step < 1) manual_step = 8'd1;
                        if (manual_step > step_max_u8) manual_step = step_max_u8;
                        act_lo      = adapt_thresh_lo;
                        act_hi      = (adapt_thresh_hi < adapt_thresh_lo) ? adapt_thresh_lo : adapt_thresh_hi;

                        if (!adapt_enable) begin
                            budget_next = step_max_u8;
                        end else if (!adapt_auto) begin
                            budget_next = manual_step;
                        end else begin
                            budget_next = budget_curr;
                            if (adapt_cycle_limit != 32'd0 && eng_cycles > adapt_cycle_limit && budget_next > min_step)
                                budget_next = budget_next - 1'b1;
                            else begin
                                if (eng_activity > act_hi && budget_next < max_step)
                                    budget_next = budget_next + 1'b1;
                                else if (eng_activity < act_lo && budget_next > min_step)
                                    budget_next = budget_next - 1'b1;
                            end
                            if (adapt_use_heavy && heavy_opcode && budget_next > min_step)
                                budget_next = budget_next - 1'b1;
                        end

                        if (budget_next < 8'd1) budget_next = 8'd1;
                        if (budget_next > step_max_u8) budget_next = step_max_u8;

                        step_budget[cur_job] <= budget_next;
                        cur_budget           <= budget_next;

                        step_cnt_inc = step_cnt + 1'b1;

                        if (step_cnt_inc < budget_next) begin
                            step_cnt <= step_cnt_inc;
                            st       <= S_IDLE;
                        end else begin
                            step_cnt <= 8'd0;
                            if (cur_layer == (DEPTH-1)) begin
                                job_done[cur_job] <= 1'b1;
                                cur_layer <= {LAYER_W{1'b0}};
                                cur_job   <= next_job;
                                st        <= S_NEXTJ;
                            end else begin
                                cur_layer <= cur_layer + 1'b1;
                                st        <= S_NEXTL;
                            end
                        end
                    end
                end

                S_NEXTL: begin
                    st <= S_IDLE;
                end

                S_NEXTJ: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

    // Engine busy indicator (includes scheduler waiting)
    wire engine_active = (st != S_IDLE) || eng_busy;

    // -------------------------------------------------------------------------
    // CSR read mux
    // -------------------------------------------------------------------------
    wire [JOB_W-1:0] status_idx = ($unsigned(status_job_sel) < N_JOBS) ? status_job_sel : {JOB_W{1'b0}};
    wire [7:0] status_budget = step_budget[status_idx];
    wire [31:0] status_activity = last_activity[status_idx];
    wire [31:0] status_cycles   = last_cycles[status_idx];

    always @* begin
        csr_rdata = 32'h0;
        if (csr_re) begin
            case (csr_addr)
                `CSR_STATUS: begin
                    csr_rdata = { {(32-N_JOBS-1){1'b0}}, job_done, engine_active };
                end
                `CSR_ADAPT_STATUS: begin
                    csr_rdata = { status_cycles[15:0], status_activity[15:0] };
                end
                `CSR_ADAPT_BUDGET: begin
                    csr_rdata = { adapt_max_steps, adapt_min_steps, status_budget, adapt_manual_steps };
                end
                `CSR_UNIT_CTRL: begin
                    csr_rdata = { 16'd0,
                                  unit_pressure_iters,
                                  4'd0,
                                  unit_pressure_diag_override,
                                  unit_overflow_reverse_bottom,
                                  unit_overflow_reverse_top,
                                  unit_flux_enable };
                end
                `CSR_UNIT_STATUS_WINDOW: begin
                    csr_rdata = { unit_window_height[status_idx], unit_window_width[status_idx] };
                end
                `CSR_UNIT_STATUS_OFFSET: begin
                    csr_rdata = { unit_window_yoff[status_idx], unit_window_xoff[status_idx] };
                end
                `CSR_UNIT_FLUX_WEIGHT_TOP: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_weight_top};
                end
                `CSR_UNIT_FLUX_WEIGHT_BOTTOM: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_weight_bottom};
                end
                `CSR_UNIT_FLUX_WEIGHT_SIDE: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_weight_side};
                end
                `CSR_UNIT_FLUX_WEIGHT_RETAIN: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_weight_retain};
                end
                `CSR_UNIT_FLUX_WEIGHT_PREV: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_weight_prev};
                end
                `CSR_UNIT_FLUX_THRESHOLD: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_flux_threshold};
                end
                `CSR_UNIT_FLUX_REVERSE_TOP: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_flux_reverse_top};
                end
                `CSR_UNIT_FLUX_REVERSE_BOTTOM: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_flux_reverse_bottom};
                end
                `CSR_UNIT_PRESSURE_GAIN: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_pressure_gain};
                end
                `CSR_UNIT_BACKPROP_LR: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_backprop_lr};
                end
                `CSR_UNIT_BACKPROP_NEIGH: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_backprop_neigh};
                end
                `CSR_UNIT_BACKPROP_DECAY: begin
                    csr_rdata = {{(32-DATA_W){1'b0}}, unit_backprop_decay};
                end
                default: csr_rdata = 32'h0;
            endcase
        end
    end
endmodule
