// =============================================================================
// sand_defs.vh  — shared parameters/opcodes
// =============================================================================

`ifndef SAND_DEFS_VH
`define SAND_DEFS_VH

// -------- Core tunables (edit freely) ----------------------------------------
`define DATA_W 16      // cell data width (fixed-point ok)
`define FRAC_W 8       // if using fixed-point (Q8.8 by default)
`define WIDTH 32      // grid X (edit as resources allow)
`define HEIGHT 32      // grid Y
`define DEPTH 4       // grid Z (layers); set 1 for pure 2D
`define N_JOBS 4       // number of sandboxes time-sliced
`define STEPS_PER_SLICE 8       // steps per job before rotating
`define USE_DIAGONALS 1       // 1: 8-neighborhood, 0: 4-neighborhood

// Host-visible config space (simple memory-mapped “CSR” window)
`define CSR_ADDR_W 8
// CSR map (byte/word addressing up to you). Minimal set:
`define CSR_JOB_SELECT 8'h00   // W: selects active job when manually poked
`define CSR_RULE_OP 8'h04   // W: opcode selector (see opcodes below)
`define CSR_RULE_CONSTA 8'h08   // W: constA (DATA_W)
`define CSR_RULE_CONSTB 8'h0C   // W: constB (DATA_W)
`define CSR_FLAGS 8'h10   // W: [0]=enable_diagonals override, [1]=use_microcode
`define CSR_STATUS 8'h14   // R: [0]=engine_busy, [N_JOBS:1]=job_done bits
`define CSR_ADAPT_CTRL 8'h18   // W: [0]=enable, [1]=auto, step budgets packed
`define CSR_ADAPT_THRESH_LO 8'h1C   // W: activity threshold low
`define CSR_ADAPT_THRESH_HI 8'h20   // W: activity threshold high
`define CSR_ADAPT_CAPACITY 8'h24   // W: cycle budget hint for frame runtime (0=ignore)
`define CSR_ADAPT_STATUS 8'h28   // R: packed status for selected job
`define CSR_ADAPT_STATUS_SEL 8'h2C   // W: selects which job to expose via STATUS register
`define CSR_ADAPT_BUDGET 8'h30   // R: step budget + misc info for selected job
`define CSR_RULE_CONSTC 8'h34   // W: constC / mix coefficient C
`define CSR_RULE_CONSTD 8'h38   // W: constD / mix bias term
`define CSR_MICRO_BASE 8'h40   // W: microcode table (16 entries)

// Enhanced unit controls
`define CSR_UNIT_CTRL 8'h50   // W: unit behavior enable bits + iteration counts
`define CSR_UNIT_WINDOW_WH 8'h54   // W: {height[31:16], width[15:0]} for selected job
`define CSR_UNIT_WINDOW_OFFSET 8'h58   // W: {y_off[31:16], x_off[15:0]} for selected job
`define CSR_UNIT_FLUX_WEIGHT_TOP 8'h5C   // W: weight for north/top flux
`define CSR_UNIT_FLUX_WEIGHT_BOTTOM 8'h60  // W: weight for south/bottom flux
`define CSR_UNIT_FLUX_WEIGHT_SIDE 8'h64   // W: weight for lateral/diagonal flux
`define CSR_UNIT_FLUX_WEIGHT_RETAIN 8'h68  // W: retention/self weight
`define CSR_UNIT_FLUX_WEIGHT_PREV 8'h6C   // W: previous-layer feedback weight
`define CSR_UNIT_FLUX_THRESHOLD 8'h70   // W: saturation threshold for flux accumulator
`define CSR_UNIT_FLUX_REVERSE_TOP 8'h74   // W: fraction of overflow sent back upward
`define CSR_UNIT_FLUX_REVERSE_BOTTOM 8'h78 // W: fraction of overflow drained downward
`define CSR_UNIT_PRESSURE_GAIN 8'h7C   // W: exchange rate gain
`define CSR_UNIT_BACKPROP_LR 8'h80   // W: learning rate for backprop mode
`define CSR_UNIT_BACKPROP_NEIGH 8'h84   // W: neighbor-coupled gradient gain
`define CSR_UNIT_BACKPROP_DECAY 8'h88   // W: decay/regularization factor
`define CSR_UNIT_STATUS_WINDOW 8'h8C   // R: {height[31:16], width[15:0]} for selected job
`define CSR_UNIT_STATUS_OFFSET 8'h90   // R: {y_off[31:16], x_off[15:0]} for selected job

// Adaptive scheduler defaults
`define ADAPT_DEFAULT_MANUAL_STEPS `STEPS_PER_SLICE
`define ADAPT_DEFAULT_MIN_STEPS 1
`define ADAPT_DEFAULT_MAX_STEPS `STEPS_PER_SLICE
`define ADAPT_DEFAULT_LOW_THRESH 16
`define ADAPT_DEFAULT_HIGH_THRESH (((`WIDTH*`HEIGHT) > 0) ? ((`WIDTH*`HEIGHT) >> 1) : 1)
`define ADAPT_DEFAULT_CAP_CYCLES 0

// Opcodes for the PE ALU (baseline “math”)
`define OPCODE_W 5
`define OP_NOP 5'd0
`define OP_SELF 5'd1
`define OP_SUM_NBRS 5'd2
`define OP_AVG_NBRS 5'd3
`define OP_ADD_CONST 5'd4
`define OP_SUB_CONST 5'd5
`define OP_MUL_CONST 5'd6
`define OP_DIV_CONST 5'd7
`define OP_DIFFUSION 5'd8  // self + k*(avg_nbrs - self)
`define OP_MIN 5'd9  // min(self, any neighbor)
`define OP_MAX 5'd10 // max(self, any neighbor)
`define OP_CLAMP 5'd11 // clamp(self, constA..constB)
`define OP_WATER_FLUX 5'd12 // weighted flux accumulation with overflow routing
`define OP_PRESSURE 5'd13 // iterative pressure/exchange solver
`define OP_BACKPROP 5'd14 // simple backprop-style gradient update
`define OP_MICRO 5'd15 // microcode lookup (default)
`define OP_LAPLACIAN 5'd16 // 6-neighbor laplacian (planar + vertical)
`define OP_SHARPEN 5'd17 // self + alpha*(laplacian) with alpha=constA
`define OP_EDGE 5'd18 // |dx|+|dy| using 4-neighbor gradients
`define OP_MIX 5'd19 // a*self + b*avg + c*sum + d (fixed-point mix)

`endif
