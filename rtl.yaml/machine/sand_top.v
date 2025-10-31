`include "sand_defs.vh"



module sand_top
(
  input wire clk,
  input wire rst,
  input wire csr_we,
  input wire csr_re,
  input wire [7:0] csr_addr,
  input wire [31:0] csr_wdata,
  output wire [31:0] csr_rdata,
  input wire seed_we,
  input wire [$clog2(4)-1:0] seed_job,
  input wire [$clog2(4)-1:0] seed_layer,
  input wire [$clog2((32*32))-1:0] seed_idx,
  input wire [16-1:0] seed_data,
  output wire [4-1:0] job_done
);


  sand_scheduler_dynamic
  #(
    .DATA_W(16),
    .WIDTH(32),
    .HEIGHT(32),
    .DEPTH(4),
    .N_JOBS(4)
  )
  u_sched
  (
    .clk(clk),
    .rst(rst),
    .csr_we(csr_we),
    .csr_addr(csr_addr),
    .csr_wdata(csr_wdata),
    .csr_re(csr_re),
    .csr_rdata(csr_rdata),
    .seed_we(seed_we),
    .seed_job(seed_job),
    .seed_layer(seed_layer),
    .seed_idx(seed_idx),
    .seed_data(seed_data),
    .job_done(job_done)
  );


endmodule

