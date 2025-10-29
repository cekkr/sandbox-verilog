# 🎛️ Sandbox Scenario Presets

This guide collects the ready-to-run presets that used to live in the top-level README. Each preset highlights a distinct behaviour—diffusion, percolation, cellular automata, morphology, neural activation fields, and sharpening—and can be reproduced by driving the control/status registers (CSRs) plus the seed port.

> **Notation**
>
> - `W,H,D` = `WIDTH, HEIGHT, DEPTH`
> - `Qm.n` = fixed-point format (`DATA_W=16`, `FRAC_W=8` → **Q8.8**)
> - `k` = diffusion coefficient in Q8.8 (`0x0100` ≈ 1.0)

---

## 1) Smooth Diffusion (2D heat map)

**Interpretation:** Dye diffusing on a plate.  
**Use case:** Blurring, smoothing fields, gentle consensus.

**Params (`sand_defs.vh`):**

- `W=64, H=64, D=1, USE_DIAGONALS=1`
- `DATA_W=16, FRAC_W=8`

**CSR:**

- `CSR_RULE_OP = OP_DIFFUSION`
- `CSR_RULE_CONSTA = 0x0040` (k ≈ 0.25)
- `CSR_FLAGS = diag=1, micro=0`
- `STEPS_PER_SLICE = 8` (default OK)

**Seeding:** Bright dot in the centre  
`job=0, layer=0, idx=(H/2)*W + (W/2) = 32*64+32`  
`seed_data=0x3F00` (≈ 63.0 in Q8.8)

**Result:** Symmetric glow that spreads and fades.

---

## 2) Falling Sand / Water Percolation (3D)

**Interpretation:** Material flows down through porous layers.  
**Use case:** Sand/water toys, erosion simulations, vertical transport.

**Params:**

- `W=64, H=64, D=8, USE_DIAGONALS=0`

**CSR:**

- `CSR_RULE_OP = OP_MIX`
- `CSR_RULE_CONSTA = 0x0100` (retain 100% of current value)
- `CSR_RULE_CONSTB = 0x0020` (blend 1/8 planar average)
- `CSR_RULE_CONSTC = 0x0010` (drip 1/16 vertical neighbours)
- `CSR_RULE_CONSTD = 0x0000`
- `CSR_FLAGS = diag=0, micro=0`

**Seeding:** Fill top layer (`z=0`) near the edge with `seed_data=0x0200..0x0800` for `x=0..63, y=0..4`.

**Result:** Horizontal spread with gentle vertical bleed as lower layers accumulate overflow.

---

## 3) “Cellular Automaton Lite” (threshold diffusion with microcode)

**Interpretation:** CA-like toggling with local averaging.  
**Use case:** Edge emergence, reaction-diffusion vibes.

**Params:**

- `W=64, H=64, D=1, USE_DIAGONALS=1`
- `DATA_W=16, FRAC_W=8`

**CSR:**

- `CSR_RULE_OP = OP_MICRO`
- `CSR_FLAGS = diag=1, micro=1`

**Microcode LUT (16 entries):**  
Default index `micro_idx = { opcode[1:0], self[1:0] }`.

- Entries 0–7: `0x0000` (off)  
- Entries 8–15: `0x0100` (on)

> Tip: For average-driven behaviour, re-map `micro_idx` inside `sand_pe` to use `avg_nbrs[9:8]`.

**Seeding:** Random speckle (~5% cells set to `0x0100`).

**Result:** Patches expand or contract to stable boundaries based on local density.

---

## 4) Min/Max Morphology (dilation/erosion)

**Interpretation:** Nonlinear morphology.  
**Use case:** Blob growth/shrink, denoising.

**Params:** `W=64, H=64, D=1, USE_DIAGONALS=1`

- Dilation: `CSR_RULE_OP = OP_MAX`  
- Erosion: `CSR_RULE_OP = OP_MIN`

**Seeding:** Binary mask (`0x0000` / `0x0100`).

**Result:** Alternating passes grow and shrink shapes, similar to morphological opening/closing.

---

## 5) Neural-ish Activation Field

**Interpretation:** 3D weighted blend → smooth activation → adaptive bias → spike readout.  
**Use case:** Tiny neural cellular automaton with feedback and self-tuning.

**Params (demo harness):**

- `W=32, H=32, D=4` (testbench window defaults to 6×6×3)
- `sand_circuit_neighbor_mix` with programmable gains
- `sand_circuit_activation_micro_lut` sampled to mirror the Q8.8 softsign curve
- Iterative bias update toward a target activation level
- Readout neuron combining depth-averaged activations into a spike heatmap
- Optional hex dataset loader (clamped, tiled to fit)
- Per-layer feedback plusargs for differentiated responses

**Run it:**  
`python3 examples/neural_activation_field/run.py --config examples/neural_activation_field/configs/default.yaml`

**Result:** Iterative telemetry, ASCII volumes with self-organising plateaus, and a spike heatmap that tracks consistently excited regions.

---

## 6) Laplacian Sharpening Pass

**Interpretation:** Classic unsharp mask using the Laplacian.  
**Use case:** Embossed textures, field enhancement before thresholding.

**Params:** `W=128, H=128, D=1, USE_DIAGONALS=1`

- `CSR_RULE_OP = OP_SHARPEN`
- `CSR_RULE_CONSTA = 0x0080` (α ≈ 0.5)
- `CSR_FLAGS = diag=1, micro=0`

**Seeding:** Grayscale height map or image.

**Result:** Edges brighten while flat regions remain close to input levels.

---

## 7) Edge Detector Slice

**Interpretation:** Gradient magnitude `|e-w| + |s-n|`.  
**Use case:** Boundary highlighting before microcode/learning stages.

- `CSR_RULE_OP = OP_EDGE`
- `CSR_FLAGS = diag=0, micro=0`

**Pipeline tip:** Run `OP_EDGE` into plane B, keep the original data in plane A, then feed the edge map into `OP_MICRO` or `OP_DIFFUSION` on the next slice.

**Result:** Bright ridges along transitions; flat regions near zero.

