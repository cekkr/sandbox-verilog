// =============================================================================
// sand_scheduler.v — round-robin time-slicer across jobs & layers
// - LOAD layer -> RUN steps -> STORE layer -> next layer -> next job
// - Exposes a very small CSR bus for config + microcode
// - Engine uses fully-parallel grid, so LOAD/STORE streams buffers in/out
// =============================================================================
`include "sand_defs.vh"

module sand_scheduler #(
    parameter DATA_W = `DATA_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT,
    parameter DEPTH  = `DEPTH,
    parameter N_JOBS = `N_JOBS
)(
    input  wire                   clk,
    input  wire                   rst,

    // Tiny CSR bus (write-only except STATUS)
    input  wire                   csr_we,
    input  wire [7:0]             csr_addr,
    input  wire [31:0]            csr_wdata,
    input  wire                   csr_re,
    output reg  [31:0]            csr_rdata,

    // Optional external seed/load interface (not fully elaborated; example)
    input  wire                   seed_we,
    input  wire [$clog2(N_JOBS)-1:0] seed_job,
    input  wire [$clog2(DEPTH)-1:0]  seed_layer,
    input  wire [$clog2(WIDTH*HEIGHT)-1:0] seed_idx,
    input  wire [DATA_W-1:0]      seed_data,

    // DONE pulse per job (bitmask)
    output reg  [N_JOBS-1:0]      job_done
);
    localparam CELLS = WIDTH*HEIGHT;

    // ----------------- Config Registers --------------------------------------
    reg [3:0]           opcode;
    reg [DATA_W-1:0]    constA, constB;
    reg                 force_diag, use_micro;
    reg [$clog2(N_JOBS)-1:0] forced_job_sel;

    // Microcode LUT shared (16 entries)
    reg [DATA_W-1:0] micro_lut [0:15];

    // CSR write
    integer mi;
    always @(posedge clk) begin
        if (rst) begin
            opcode <= `OP_DIFFUSION;
            constA <= { {(DATA_W-`FRAC_W){1'b0}}, {`FRAC_W{1'b1}} } >> 1; // ~0.5
            constB <= {DATA_W{1'b0}};
            force_diag <= `USE_DIAGONALS[0];
            use_micro  <= 1'b0;
            forced_job_sel <= {($clog2(N_JOBS)){1'b0}};
            for (mi=0; mi<16; mi=mi+1) micro_lut[mi] <= {DATA_W{1'b0}};
        end else if (csr_we) begin
            case (csr_addr)
                `CSR_JOB_SELECT:   forced_job_sel <= csr_wdata[$clog2(N_JOBS)-1:0];
                `CSR_RULE_OP:      opcode         <= csr_wdata[3:0];
                `CSR_RULE_CONSTA:  constA         <= csr_wdata[DATA_W-1:0];
                `CSR_RULE_CONSTB:  constB         <= csr_wdata[DATA_W-1:0];
                `CSR_FLAGS:        begin
                                    force_diag    <= csr_wdata[0];
                                    use_micro     <= csr_wdata[1];
                                   end
                default: begin
                    if (csr_addr >= `CSR_MICRO_BASE && csr_addr < (`CSR_MICRO_BASE+16)) begin
                        micro_lut[csr_addr-`CSR_MICRO_BASE] <= csr_wdata[DATA_W-1:0];
                    end
                end
            endcase
        end
    end

    // CSR read (STATUS)
    wire engine_busy;
    always @* begin
        if (csr_re && csr_addr==`CSR_STATUS) csr_rdata = { {(32-N_JOBS-1){1'b0}}, job_done, engine_busy };
        else                                 csr_rdata = 32'h0;
    end

    // ----------------- Job/Layers Memory -------------------------------------
    wire mem_wr_en   = seed_we;
    wire mem_rd_en   = 1'b0; // reads happen during LOAD via dedicated control

    wire [DATA_W-1:0] mem_rd_data;
    sand_jobmem #(
        .DATA_W(DATA_W), .WIDTH(WIDTH), .HEIGHT(HEIGHT),
        .DEPTH(DEPTH), .N_JOBS(N_JOBS)
    ) u_jobmem (
        .clk(clk),
        .wr_en(mem_wr_en),
        .rd_en(mem_rd_en),
        .job_id(seed_job),
        .layer_id(seed_layer),
        .cell_idx(seed_idx),
        .wr_data(seed_data),
        .rd_data(mem_rd_data)
    );

    // ----------------- On-chip working buffers (ping-pong layer frames) ------
    // For the active job+layer, we load into read_buf, compute write_buf, then swap.
    // Represent as 2D arrays of regs for clarity (synth: becomes flops/BRAM).
    reg [DATA_W-1:0] read_buf  [0:HEIGHT-1][0:WIDTH-1];
    wire[DATA_W-1:0] write_buf [0:HEIGHT-1][0:WIDTH-1];

    // ----------------- Grid compute fabric -----------------------------------
    wire [3:0] eff_opcode   = use_micro ? `OP_MICRO : opcode;
    wire       eff_diagonals= force_diag;

    sand_grid #(
        .DATA_W(DATA_W), .WIDTH(WIDTH), .HEIGHT(HEIGHT)
    ) u_grid (
        .clk(clk),
        .rst(rst),
        .read_buf(read_buf),
        .write_buf(write_buf),
        .opcode(eff_opcode),
        .use_diagonals(eff_diagonals),
        .constA(constA),
        .constB(constB),
        .micro_lut(micro_lut)
    );

    // ----------------- Scheduler FSM -----------------------------------------
    localparam S_IDLE  = 3'd0,
               S_LOAD  = 3'd1,
               S_RUN   = 3'd2,
               S_STORE = 3'd3,
               S_NEXTL = 3'd4,
               S_NEXTJ = 3'd5;

    reg [2:0]  st;
    reg [$clog2(N_JOBS)-1:0] cur_job;
    reg [$clog2(DEPTH)-1:0]  cur_layer;
    reg [$clog2(CELLS)-1:0]  cell_cnt;
    reg [$clog2(`STEPS_PER_SLICE)-1:0] step_cnt;

    assign engine_busy = (st != S_IDLE);

    // simple round-robin unless user forces a job via CSR_JOB_SELECT (optional)
    wire [$clog2(N_JOBS)-1:0] next_job = (cur_job == N_JOBS-1) ? {($clog2(N_JOBS)){1'b0}} : (cur_job+1);

    // “Read” from jobmem into read_buf (one cell per cycle)
    // “Store” write_buf back into jobmem similarly
    // Map (x,y) => linear index
    wire [$clog2(WIDTH)-1:0]  buf_x = cell_cnt % WIDTH;
    wire [$clog2(HEIGHT)-1:0] buf_y = cell_cnt / WIDTH;

    // For brevity, reuse the same jobmem with a small muxed access model
    // (In a real design, you'd give the scheduler explicit read/write ports.)
    reg jobmem_wr;
    reg jobmem_rd;
    reg [$clog2(N_JOBS)-1:0]  jobmem_job;
    reg [$clog2(DEPTH)-1:0]   jobmem_layer;
    reg [$clog2(CELLS)-1:0]   jobmem_idx;
    reg [DATA_W-1:0]          jobmem_wdata;
    wire[DATA_W-1:0]          jobmem_rdata;

    // Tie our scheduler-controlled port into the same BRAM instance
    // (Multiplex with seed port through one-hot gating; here we just time-share)
    // For simplicity in this self-contained code, instantiate another bram for r/w:
    // In production, consolidate ports/arbiter.
    bram_dp #(
        .DATA_W(DATA_W),
        .ADDR_W($clog2(N_JOBS*DEPTH*CELLS))
    ) u_jobmem_sched (
        .clk(clk),
        .a_we(jobmem_wr),
        .a_addr((((jobmem_job*DEPTH)+jobmem_layer)*CELLS)+jobmem_idx),
        .a_din(jobmem_wdata),
        .a_dout(),
        .b_we(1'b0),
        .b_addr((((jobmem_job*DEPTH)+jobmem_layer)*CELLS)+jobmem_idx),
        .b_din({DATA_W{1'b0}}),
        .b_dout(jobmem_rdata)
    );

    integer ix;
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            cur_job <= {($clog2(N_JOBS)){1'b0}};
            cur_layer <= {($clog2(DEPTH)){1'b0}};
            cell_cnt <= {($clog2(CELLS)){1'b0}};
            step_cnt <= {($clog2(`STEPS_PER_SLICE)){1'b0}};
            job_done <= {N_JOBS{1'b0}};
            jobmem_wr <= 1'b0; jobmem_rd <= 1'b0;
        end else begin
            // defaults
            jobmem_wr <= 1'b0; jobmem_rd <= 1'b0;

            case (st)
                S_IDLE: begin
                    // Start with job 0, layer 0
                    cur_job   <= cur_job;
                    cur_layer <= {($clog2(DEPTH)){1'b0}};
                    cell_cnt  <= 0;
                    step_cnt  <= 0;
                    st <= S_LOAD;
                end

                S_LOAD: begin
                    // stream from job memory into read_buf
                    jobmem_job   <= cur_job;
                    jobmem_layer <= cur_layer;
                    jobmem_idx   <= cell_cnt;
                    jobmem_rd    <= 1'b1;

                    // write into read_buf on the next cycle (1-cycle latency model)
                    // Here we do a simple synchronous write assuming bram_dp read latency 1
                    // To keep the code compact, assign immediately; for real BRAM, register rdata then write.
                    read_buf[buf_y][buf_x] <= jobmem_rdata;

                    if (cell_cnt == CELLS-1) begin
                        cell_cnt <= 0;
                        st <= S_RUN;
                    end else begin
                        cell_cnt <= cell_cnt + 1;
                    end
                end

                S_RUN: begin
                    // Grid computes one step per clock (fully parallel fabric).
                    // Let write_buf fill this cycle; then copy write->read for ping-pong.
                    // (To save flops, we copy in-place next cycle—simple but O(W*H).)
                    // Here we “copy” immediately for clarity; in practice, add a COPY state.
                    for (ix=0; ix<CELLS; ix=ix+1) begin end // prevent empty loop warnings
                    // Copy phase
                    read_buf[buf_y][buf_x] <= write_buf[buf_y][buf_x];

                    // Iterate across the whole grid to effect the copy; we use cell_cnt to raster
                    if (cell_cnt == CELLS-1) begin
                        cell_cnt <= 0;
                        step_cnt <= step_cnt + 1;
                        if (step_cnt == (`STEPS_PER_SLICE-1)) begin
                            step_cnt <= 0;
                            st <= S_STORE;
                        end
                    end else begin
                        cell_cnt <= cell_cnt + 1;
                    end
                end

                S_STORE: begin
                    // stream read_buf (current state) out to job memory
                    jobmem_job   <= cur_job;
                    jobmem_layer <= cur_layer;
                    jobmem_idx   <= cell_cnt;
                    jobmem_wdata <= read_buf[buf_y][buf_x];
                    jobmem_wr    <= 1'b1;

                    if (cell_cnt == CELLS-1) begin
                        cell_cnt <= 0;
                        st <= S_NEXTL;
                    end else begin
                        cell_cnt <= cell_cnt + 1;
                    end
                end

                S_NEXTL: begin
                    if (cur_layer == DEPTH-1) begin
                        // one full volume processed for this time slice
                        job_done[cur_job] <= 1'b1; // sticky until read via CSR (optional clear logic)
                        cur_layer <= 0;
                        st <= S_NEXTJ;
                    end else begin
                        cur_layer <= cur_layer + 1;
                        st <= S_LOAD;
                    end
                end

                S_NEXTJ: begin
                    cur_job <= next_job;
                    st <= S_LOAD;
                end
            endcase
        end
    end

endmodule
