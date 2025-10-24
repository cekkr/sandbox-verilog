// =============================================================================
// sand_jobmem.v — per-job ping-pong layer buffers in BRAM
// - Stores DEPTH layers per job, each layer is WIDTH*HEIGHT cells
// - Provides layer load/store for scheduler
// =============================================================================
`include "sand_defs.vh"

module sand_jobmem #(
    parameter DATA_W = `DATA_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT,
    parameter DEPTH  = `DEPTH,
    parameter N_JOBS = `N_JOBS
)(
    input  wire                   clk,
    // Simple layer port (single layer per transaction)
    input  wire                   wr_en,     // write one cell
    input  wire                   rd_en,     // read one cell
    input  wire [$clog2(N_JOBS)-1:0] job_id,
    input  wire [$clog2(DEPTH)-1:0]  layer_id,
    input  wire [$clog2(WIDTH*HEIGHT)-1:0] cell_idx,
    input  wire [DATA_W-1:0]      wr_data,
    output wire [DATA_W-1:0]      rd_data
);
    localparam ADDR_W = $clog2(N_JOBS*DEPTH*WIDTH*HEIGHT);
    localparam CELLS  = WIDTH*HEIGHT;
    // Address mapping: (((job*DEPTH)+layer)*CELLS)+cell_idx
    wire [ADDR_W-1:0] addr = ((((job_id*DEPTH)+layer_id)*CELLS) + cell_idx);

    bram_dp #(
        .DATA_W(DATA_W),
        .ADDR_W(ADDR_W)
    ) u_mem (
        .clk   (clk),
        .a_we  (wr_en),
        .a_addr(addr),
        .a_din (wr_data),
        .a_dout(),           // unused on A
        .b_we  (1'b0),
        .b_addr(addr),
        .b_din ({DATA_W{1'b0}}),
        .b_dout(rd_data)
    );
endmodule
