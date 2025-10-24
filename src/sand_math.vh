// =============================================================================
// sand_math.vh — Saturating/Rounding fixed‑point helpers
// Drop‑in include for sand_pe and other modules.
// Macros let you switch between wrap vs saturate, round vs truncate.
// =============================================================================

`ifndef SAND_MATH_VH
`define SAND_MATH_VH

// ---- Tunables ---------------------------------------------------------------
`ifndef SATURATE
 `define SATURATE 1       // 1: clamp on overflow, 0: wrap
`endif
`ifndef ROUND_MUL
 `define ROUND_MUL 1      // 1: round on >> FRAC_W, 0: truncate
`endif

// ---- Local helpers ----------------------------------------------------------
`define _MAXW(DATA_W)   {DATA_W{1'b1}}
`define _MINW(DATA_W)   {DATA_W{1'b0}}

// Saturating add/sub on DATA_W bits
`define SAT_ADD(a,b,DATA_W) \
    ( {1'b0,(a)} + {1'b0,(b)} ) [DATA_W] ? ` _MAXW(DATA_W) : ( (a) + (b) )

`define SAT_SUB(a,b,DATA_W) \
    ( {1'b0,(a)} < {1'b0,(b)} ) ? ` _MINW(DATA_W) : ( (a) - (b) )

// Fixed‑point multiply by constant (QFRAC)
`define FP_MUL_Q(a,c,FRAC_W) \
    ( `ROUND_MUL ? ( ((a) * (c)) + (1<<(FRAC_W-1)) ) >>> (FRAC_W) : ((a) * (c)) >>> (FRAC_W) )

// Fixed‑point divide by constant (QFRAC). Caller must guard c!=0.
`define FP_DIV_Q(a,c,FRAC_W) \
    ( ((a) <<< (FRAC_W)) / (c) )

// Public inline functions (use inside always/assign)
`define FP_ADD(a,b,DATA_W) ( `SATURATE ? `SAT_ADD((a),(b),DATA_W) : ((a)+(b)) )
`define FP_SUB(a,b,DATA_W) ( `SATURATE ? `SAT_SUB((a),(b),DATA_W) : ((a)-(b)) )

`endif