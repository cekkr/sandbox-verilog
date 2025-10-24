// Note: The u_prog task is illustrative; in this draft, jm_job, jm_layer, and jm_plane_sel are 
//  regular regs driven directly by the scheduler through the engine’s exposed regs. Keep or remove the task.

`include "sand_defs.vh"

module sand_scheduler_ps #(
    parameter DATA_W = `DATA_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT,
    parameter DEPTH  = `DEPTH,
    parameter N_JOBS = `N_JOBS
)(
    input  wire                   clk,
    input  wire                   rst,

    // CSR (same map; add plane/status if desired)
    input  wire                   csr_we,
    input  wire [7:0]             csr_addr,
    input  wire [31:0]            csr_wdata,
    input  wire                   csr_re,
    output reg  [31:0]            csr_rdata,

    // Seed port passthrough to jobmem2p
    input  wire                   seed_we,
    input  wire [$clog2(N_JOBS)-1:0] seed_job,
    input  wire [$clog2(DEPTH)-1:0]  seed_layer,
    input  wire                      seed_plane,
    input  wire [$clog2(WIDTH*HEIGHT)-1:0] seed_idx,
    input  wire [DATA_W-1:0]      seed_data,

    output reg  [N_JOBS-1:0]      job_done
);
    localparam CELLS = WIDTH*HEIGHT;

    // --- Config registers (reuse from original) ------------------------------
    reg [3:0]           opcode;    reg [DATA_W-1:0] constA, constB;
    reg                 force_diag, use_micro;
    reg [$clog2(N_JOBS)-1:0] forced_job_sel;
    reg [DATA_W-1:0] micro_lut [0:15];

    integer mi;
    always @(posedge clk) begin
        if (rst) begin
            opcode<=`OP_DIFFUSION; constA<=16'h0080; constB<=0; force_diag<=`USE_DIAGONALS[0]; use_micro<=1'b0; forced_job_sel<=0;
            for (mi=0; mi<16; mi=mi+1) micro_lut[mi]<=0;
        end else if (csr_we) begin
            case (csr_addr)
                `CSR_JOB_SELECT:  forced_job_sel <= csr_wdata[$clog2(N_JOBS)-1:0];
                `CSR_RULE_OP:     opcode         <= csr_wdata[3:0];
                `CSR_RULE_CONSTA: constA         <= csr_wdata[DATA_W-1:0];
                `CSR_RULE_CONSTB: constB         <= csr_wdata[DATA_W-1:0];
                `CSR_FLAGS:       begin force_diag<=csr_wdata[0]; use_micro<=csr_wdata[1]; end
                default: if (csr_addr>=`CSR_MICRO_BASE && csr_addr<(`CSR_MICRO_BASE+16))
                    micro_lut[csr_addr-`CSR_MICRO_BASE] <= csr_wdata[DATA_W-1:0];
            endcase
        end
    end

    // CSR readback (busy + job_done)
    wire engine_busy; assign engine_busy = (st!=S_IDLE);
    always @* begin
        if (csr_re && csr_addr==`CSR_STATUS) csr_rdata = { {(32-N_JOBS-1){1'b0}}, job_done, engine_busy };
        else csr_rdata = 32'h0;
    end

    // --- Plane bit table per (job, layer) -----------------------------------
    reg plane_sel [0:N_JOBS-1][0:DEPTH-1]; // 0 or 1 indicates current READ plane

    // --- Job memory (two‑plane) ---------------------------------------------
    wire jm_we; wire [$clog2(N_JOBS)-1:0] jm_job; wire [$clog2(DEPTH)-1:0] jm_layer;
    wire jm_plane_sel; wire jm_write_other_plane; wire [$clog2(CELLS)-1:0] jm_idx;
    wire [DATA_W-1:0] jm_wdata; wire [DATA_W-1:0] jm_rdata;

    sand_jobmem2p #(.DATA_W(DATA_W),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DEPTH(DEPTH),.N_JOBS(N_JOBS)) u_mem (
        .clk(clk),
        .seed_we(seed_we), .seed_job(seed_job), .seed_layer(seed_layer), .seed_plane(seed_plane),
        .seed_idx(seed_idx), .seed_data(seed_data),
        .eng_we(jm_we), .eng_job(jm_job), .eng_layer(jm_layer), .eng_plane_sel(jm_plane_sel),
        .eng_write_other_plane(jm_write_other_plane), .eng_idx(jm_idx), .eng_wdata(jm_wdata), .eng_rdata(jm_rdata)
    );

    // --- Engine --------------------------------------------------------------
    wire eng_start, eng_busy, eng_done;
    reg  start_frame;

    sand_engine_raster #(.DATA_W(DATA_W),.FRAC_W(`FRAC_W),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_eng (
        .clk(clk), .rst(rst),
        .start_frame(start_frame), .busy(eng_busy), .frame_done(eng_done),
        .opcode(use_micro ? `OP_MICRO : opcode), .use_diagonals(force_diag),
        .constA(constA), .constB(constB), .micro_lut(micro_lut),
        .jm_we(jm_we), .jm_job(jm_job), .jm_layer(jm_layer), .jm_plane_sel(jm_plane_sel),
        .jm_write_other_plane(jm_write_other_plane), .jm_idx(jm_idx), .jm_wdata(jm_wdata), .jm_rdata(jm_rdata)
    );

    // --- Scheduler FSM -------------------------------------------------------
    localparam S_IDLE=0,S_START=1,S_WAIT=2,S_NEXTL=3,S_NEXTJ=4;
    reg [2:0] st;
    reg [$clog2(N_JOBS)-1:0] cur_job;
    reg [$clog2(DEPTH)-1:0]  cur_layer;
    reg [$clog2(`STEPS_PER_SLICE)-1:0] step_cnt;

    always @(posedge clk) begin
        if (rst) begin
            st<=S_IDLE; cur_job<=0; cur_layer<=0; step_cnt<=0; start_frame<=0; job_done<={N_JOBS{1'b0}};
            integer j,l; for (j=0;j<N_JOBS;j=j+1) for (l=0;l<DEPTH;l=l+1) plane_sel[j][l]<=0;
        end else begin
            start_frame<=0;
            case (st)
                S_IDLE: begin
                    // Program engine job/layer/plane
                    u_prog(cur_job, cur_layer, plane_sel[cur_job][cur_layer]);
                    start_frame<=1; st<=S_WAIT;
                end
                S_WAIT: begin
                    if (eng_done) begin
                        // Toggle plane for this layer (pointer swap)
                        plane_sel[cur_job][cur_layer] <= ~plane_sel[cur_job][cur_layer];
                        // Count steps
                        if (step_cnt == (`STEPS_PER_SLICE-1)) begin
                            step_cnt <= 0; st<=S_NEXTL;
                        end else begin
                            step_cnt <= step_cnt + 1; // Start next frame on same layer
                            u_prog(cur_job, cur_layer, plane_sel[cur_job][cur_layer]);
                            start_frame<=1;
                        end
                    end
                end
                S_NEXTL: begin
                    if (cur_layer == DEPTH-1) begin
                        job_done[cur_job] <= 1'b1; cur_layer<=0; st<=S_NEXTJ;
                    end else begin
                        cur_layer<=cur_layer+1; st<=S_IDLE;
                    end
                end
                S_NEXTJ: begin
                    cur_job <= (cur_job==N_JOBS-1) ? 0 : (cur_job+1);
                    st<=S_IDLE;
                end
            endcase
        end
    end

    // Procedure to program engine IO (synthesizable via regs)
    task u_prog(input [$clog2(N_JOBS)-1:0] j, input [$clog2(DEPTH)-1:0] l, input p);
    begin
        // Drive the engine‑visible regs
        // (Using direct reg connections above; task kept for readability.)
        // jm_job/jm_layer/jm_plane_sel are driven by u_eng via assigned regs.
    end endtask
endmodule