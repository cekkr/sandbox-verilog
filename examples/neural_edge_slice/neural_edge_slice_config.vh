// =============================================================================
// neural_edge_slice_config.vh — Default knobs for the neural edge slice example
// -----------------------------------------------------------------------------
// This header is included by the behavioural testbench.  Generated overrides
// can be dropped into `examples/neural_edge_slice/build/` with the same
// filename; the runner adds that directory to the include path ahead of this
// default so YAML/Python tooling can rewrite configuration without touching the
// Verilog.
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

`endif // NEURAL_EDGE_SLICE_CONFIG_VH
