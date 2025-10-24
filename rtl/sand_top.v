// =============================================================================
// sand_top.v — integration wrapper
// - Exposes the scheduler CSR port (super simple), seed loader,
//   and a ready-to-synthesize sand engine.
// - Plug CSR/seed to your soft CPU/AXI-lite bridge easily.
// =============================================================================
`include "sand_defs.vh"

module sand_top (
    input  wire clk,
    input  wire rst,

    // CSR Port (toy: single-cycle ready)
    input  wire        csr_we,
    input  wire        csr_re,
    input  wire [7:0]  csr_addr,
    input  wire [31:0] csr_wdata,
    output wire [31:0] csr_rdata,

    // Seeding state (write grid initial conditions per job/layer)
    input  wire                       seed_we,
    input  wire [$clog2(`N_JOBS)-1:0] seed_job,
    input  wire [$clog2(`DEPTH)-1:0]  seed_layer,
    input  wire [$clog2(`WIDTH*`HEIGHT)-1:0] seed_idx,
    input  wire [`DATA_W-1:0]         seed_data,

    output wire [`N_JOBS-1:0]         job_done
);

    sand_scheduler_dynamic #(
        .DATA_W(`DATA_W), .WIDTH(`WIDTH), .HEIGHT(`HEIGHT),
        .DEPTH(`DEPTH), .N_JOBS(`N_JOBS)
    ) u_sched (
        .clk(clk), .rst(rst),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_wdata(csr_wdata),
        .csr_re(csr_re), .csr_rdata(csr_rdata),
        .seed_we(seed_we), .seed_job(seed_job), .seed_layer(seed_layer),
        .seed_idx(seed_idx), .seed_data(seed_data),
        .job_done(job_done)
    );

endmodule
