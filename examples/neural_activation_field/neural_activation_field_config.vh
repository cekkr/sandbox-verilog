// Default knobs for the neural activation field behavioural example.
`ifndef NEURAL_ACTIVATION_FIELD_CONFIG_VH
`define NEURAL_ACTIVATION_FIELD_CONFIG_VH

localparam integer NAF_WINDOW_W_DEFAULT   = 6;
localparam integer NAF_WINDOW_H_DEFAULT   = 6;
localparam integer NAF_WINDOW_D_DEFAULT   = 3;
localparam integer NAF_PATTERN_ID_DEFAULT = 1;
localparam integer NAF_ITERATIONS_DEFAULT = 4;

localparam integer NAF_SELF_GAIN_PCT      = 550;
localparam integer NAF_PLANAR_GAIN_PCT    = 350;
localparam integer NAF_VERTICAL_GAIN_PCT  = 250;
localparam integer NAF_BIAS_PCT           = -120;

localparam integer NAF_FEEDBACK_PCT       = 400;
localparam integer NAF_DAMP_PCT           = 100;
localparam integer NAF_LEARNING_PCT       = 120;
localparam integer NAF_TARGET_PCT         = 350;

localparam integer NAF_READ_EDGE_PCT      = 600;
localparam integer NAF_READ_RAW_PCT       = 400;
localparam integer NAF_READ_BIAS_PCT      = -100;
localparam integer NAF_READ_THRESH_PCT    = 300;

`endif  // NEURAL_ACTIVATION_FIELD_CONFIG_VH

