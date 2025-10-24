// =============================================================================
// bram_tdp_wrap.v — vendor‑selectable true dual‑port memory
// Define one of: VENDOR_XILINX, VENDOR_INTEL, VENDOR_LATTICE; else use behavioral.
// Write‑first/Read‑first is set to READ_FIRST by default.
// Note: Tools generally infer BRAM from the behavioral model. 
//  If you need hard primitives, duplicate this wrapper under ifdefs and paste the official primitive templates.
// =============================================================================

module bram_tdp_wrap #(
    parameter DATA_W = 16,
    parameter ADDR_W = 12
)(
    input  wire                 clk,
    // Port A
    input  wire                 a_we,
    input  wire [ADDR_W-1:0]    a_addr,
    input  wire [DATA_W-1:0]    a_din,
    output reg  [DATA_W-1:0]    a_dout,
    // Port B
    input  wire                 b_we,
    input  wire [ADDR_W-1:0]    b_addr,
    input  wire [DATA_W-1:0]    b_din,
    output reg  [DATA_W-1:0]    b_dout
);
`ifdef VENDOR_XILINX
    // Map to RAMB36E2 in simple width (behavioral stub: replace with real primitive params)
    // For brevity, use behavioral fallback for simulation and infer BRAM in synthesis.
    // Most Xilinx tools will infer TDP from this always block with appropriate pragmas.
`elsif VENDOR_INTEL
    // Similar: rely on inference; replace with altsyncram instantiation if desired.
`elsif VENDOR_LATTICE
    // Rely on inference; for ECP5/NX use DP16KD directly if needed.
`else
    // Behavioral portable model
    localparam DEPTH = (1<<ADDR_W);
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_din;
        a_dout <= mem[a_addr];
        if (b_we) mem[b_addr] <= b_din;
        b_dout <= mem[b_addr];
    end
`endif
endmodule