// =============================================================================
// neural_edge_slice_config.vh — Default knobs for the neural edge slice example
// =============================================================================
//
// Behavioural defaults are provided here so automated tooling can generate an
// override header without touching the main Verilog file.  The Python harness
// writes a copy of this template into build/ when YAML configs are used; the
// include search order prefers generated headers.
// =============================================================================

`ifndef NEURAL_EDGE_SLICE_CONFIG_VH
`define NEURAL_EDGE_SLICE_CONFIG_VH

localparam integer NES_WINDOW_W_DEFAULT   = 8;
localparam integer NES_WINDOW_H_DEFAULT   = 8;
localparam integer NES_PATTERN_ID_DEFAULT = 0;
localparam integer NES_EDGE_GAIN_PCT      = 700;   // thousandths (0.7x)
localparam integer NES_RAW_GAIN_PCT       = 300;   // thousandths (0.3x)
localparam integer NES_BIAS_PCT           = -250;  // thousandths (-0.25)
localparam integer NES_THRESHOLD_PCT      = 500;   // thousandths (0.5)

`endif  // NEURAL_EDGE_SLICE_CONFIG_VH
