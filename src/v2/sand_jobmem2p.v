`include "sand_defs.vh"

module sand_jobmem2p #(
    parameter DATA_W = `DATA_W,
    parameter WIDTH  = `WIDTH,
    parameter HEIGHT = `HEIGHT,
    parameter DEPTH  = `DEPTH,
    parameter N_JOBS = `N_JOBS
)(
    input  wire                   clk,
    // Seed/host port (plane explicit)
    input  wire                   seed_we,
    input  wire [$clog2(N_JOBS)-1:0] seed_job,
    input  wire [$clog2(DEPTH)-1:0]  seed_layer,
    input  wire                      seed_plane, // 0 or 1
    input  wire [$clog2(WIDTH*HEIGHT)-1:0] seed_idx,
    input  wire [DATA_W-1:0]        seed_data,

    // Engine ports (two independent ports)
    input  wire                      eng_we,
    input  wire [$clog2(N_JOBS)-1:0] eng_job,
    input  wire [$clog2(DEPTH)-1:0]  eng_layer,
    input  wire                      eng_plane_sel, // 0=planeA,1=planeB (READ plane)
    input  wire                      eng_write_other_plane, // write to !plane_sel
    input  wire [$clog2(WIDTH*HEIGHT)-1:0] eng_idx,
    input  wire [DATA_W-1:0]         eng_wdata,
    output wire [DATA_W-1:0]         eng_rdata
);
    localparam CELLS  = WIDTH*HEIGHT;
    localparam PLANES = 2;
    localparam ADDR_W = $clog2(N_JOBS*DEPTH*PLANES*CELLS);

    wire [ADDR_W-1:0] seed_addr = ((((seed_job*DEPTH)+seed_layer)*PLANES)+seed_plane)*CELLS + seed_idx;
    wire [ADDR_W-1:0] eng_raddr = ((((eng_job*DEPTH)+eng_layer)*PLANES)+eng_plane_sel)*CELLS + eng_idx;
    wire [ADDR_W-1:0] eng_waddr = ((((eng_job*DEPTH)+eng_layer)*PLANES)+(!eng_plane_sel))*CELLS + eng_idx;

    // One TDP RAM, use A=write (seed/eng), B=read (eng)
    bram_tdp_wrap #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) u_mem (
        .clk(clk),
        // A port combines seed and engine writes (seed has priority)
        .a_we  (seed_we ? 1'b1 : (eng_we & eng_write_other_plane)),
        .a_addr(seed_we ? seed_addr : eng_waddr),
        .a_din (seed_we ? seed_data : eng_wdata),
        .a_dout(),
        // B port read for engine
        .b_we  (1'b0),
        .b_addr(eng_raddr),
        .b_din ({DATA_W{1'b0}}),
        .b_dout(eng_rdata)
    );
endmodule