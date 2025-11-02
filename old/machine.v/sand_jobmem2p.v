`include "sand_defs.vh"



module sand_jobmem2p #
(
  parameter DATA_W = 16,
  parameter WIDTH = 32,
  parameter HEIGHT = 32,
  parameter DEPTH = 4,
  parameter N_JOBS = 4
)
(
  input wire clk,
  input wire seed_we,
  input wire [((N_JOBS>1)?$clog2(N_JOBS):1)-1:0] seed_job,
  input wire [((DEPTH>1)?$clog2(DEPTH):1)-1:0] seed_layer,
  input wire seed_plane,
  input wire [((WIDTH*HEIGHT>1)?$clog2((WIDTH*HEIGHT)):1)-1:0] seed_idx,
  input wire [DATA_W-1:0] seed_data,
  input wire eng_we,
  input wire [((N_JOBS>1)?$clog2(N_JOBS):1)-1:0] eng_job,
  input wire [((DEPTH>1)?$clog2(DEPTH):1)-1:0] eng_layer,
  input wire eng_plane_sel,
  input wire eng_write_other_plane,
  input wire [((WIDTH*HEIGHT>1)?$clog2((WIDTH*HEIGHT)):1)-1:0] eng_idx,
  input wire [DATA_W-1:0] eng_wdata,
  output wire [DATA_W-1:0] eng_rdata
);

  localparam CELLS = WIDTH * HEIGHT;
  localparam PLANES = 2;
  localparam ADDR_W = $clog2((N_JOBS * DEPTH * PLANES * CELLS));
  wire [ADDR_W-1:0] seed_addr;assign seed_addr = ((seed_job * DEPTH + seed_layer) * PLANES + seed_plane) * CELLS + seed_idx;
  wire [ADDR_W-1:0] eng_raddr;assign eng_raddr = ((eng_job * DEPTH + eng_layer) * PLANES + eng_plane_sel) * CELLS + eng_idx;
  wire [ADDR_W-1:0] eng_waddr;assign eng_waddr = ((eng_job * DEPTH + eng_layer) * PLANES + !eng_plane_sel) * CELLS + eng_idx;

  bram_tdp_wrap
  #(
    .DATA_W(DATA_W),
    .ADDR_W(ADDR_W)
  )
  u_mem
  (
    .clk(clk),
    .a_we((seed_we)? 1'b1 : eng_we & eng_write_other_plane),
    .a_addr((seed_we)? seed_addr : eng_waddr),
    .a_din((seed_we)? seed_data : eng_wdata),
    .a_dout(),
    .b_we(1'b0),
    .b_addr(eng_raddr),
    .b_din({ DATA_W{ 1'b0 } }),
    .b_dout(eng_rdata)
  );


endmodule

