// =============================================================================
// sand_defs.vh  — shared parameters/opcodes
// =============================================================================

`ifndef SAND_DEFS_VH
`define SAND_DEFS_VH

// -------- Core tunables (edit freely) ----------------------------------------
`define DATA_W                 16      // cell data width (fixed-point ok)
`define FRAC_W                 8       // if using fixed-point (Q8.8 by default)
`define WIDTH                  32      // grid X (edit as resources allow)
`define HEIGHT                 32      // grid Y
`define DEPTH                  4       // grid Z (layers); set 1 for pure 2D
`define N_JOBS                 4       // number of sandboxes time-sliced
`define STEPS_PER_SLICE        8       // steps per job before rotating
`define USE_DIAGONALS          1       // 1: 8-neighborhood, 0: 4-neighborhood

// Host-visible config space (simple memory-mapped “CSR” window)
`define CSR_ADDR_W             8
// CSR map (byte/word addressing up to you). Minimal set:
`define CSR_JOB_SELECT         8'h00   // W: selects active job when manually poked
`define CSR_RULE_OP            8'h04   // W: opcode selector (see opcodes below)
`define CSR_RULE_CONSTA        8'h08   // W: constA (DATA_W)
`define CSR_RULE_CONSTB        8'h0C   // W: constB (DATA_W)
`define CSR_FLAGS              8'h10   // W: [0]=enable_diagonals override, [1]=use_microcode
`define CSR_STATUS             8'h14   // R: [0]=engine_busy, [N_JOBS:1]=job_done bits
`define CSR_MICRO_BASE         8'h40   // W: microcode table (16 entries)

// Opcodes for the PE ALU (baseline “math”)
`define OP_NOP         4'd0
`define OP_SELF        4'd1
`define OP_SUM_NBRS    4'd2
`define OP_AVG_NBRS    4'd3
`define OP_ADD_CONST   4'd4
`define OP_SUB_CONST   4'd5
`define OP_MUL_CONST   4'd6
`define OP_DIV_CONST   4'd7
`define OP_DIFFUSION   4'd8  // self + k*(avg_nbrs - self)
`define OP_MIN         4'd9  // min(self, any neighbor)
`define OP_MAX         4'd10 // max(self, any neighbor)
`define OP_CLAMP       4'd11 // clamp(self, constA..constB)
`define OP_MICRO       4'd15 // 4-bit microcode index => f(self, sum, avg, etc.)

`endif
