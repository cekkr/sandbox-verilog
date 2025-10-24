# Neural Edge Slice Example

This example demonstrates how the sandbox project’s fixed-point conventions can
model a tiny neural pre-processing pipeline built around the **Edge Detector**
slice (`OP_EDGE`). A synthetic 2D field is passed through the edge detector,
combined with the raw intensity via programmable gains, and handed to a single
ReLU neuron with a configurable firing threshold. The resulting activation map
behaves like a one-layer feature extractor: bright, high-frequency regions
light up while smooth regions stay quiet.

The Verilog testbench (`neural_edge_slice_tb.v`) is intentionally behavioural.
It reuses the sandbox macros (grid dimensions, Q8.8 math) to keep the data
representation consistent with the main RTL while delegating the edge detector
and neuron maths to reusable blocks in `rtl/circuits/`. The Python harness
compiles and runs the simulation with **Icarus Verilog**, then renders the
edge/activation maps as ASCII heatmaps for quick inspection. Configuration now
flows through a YAML/JSON descriptor that the harness translates into a
generated include file so the Verilog stays static.

```
python3 examples/neural_edge_slice/run.py [--config configs/default.yaml]
                                          [--pattern cross|ramp|checker|diag]
                                          [--window-width 10] [--window-height 10]
                                          [--edge-gain 0.8] [--raw-gain 0.2]
                                          [--bias -0.2] [--threshold 0.45]
                                          [--json output.json]
```

- Parses the optional YAML/JSON config (defaults live in `configs/default.yaml`),
  generates a `neural_edge_slice_config.vh` header inside `build/`, and stitches
  in the required primitives from `rtl/circuits/`.
- Compiles `neural_edge_slice_tb.v` using the shared `tools.sand_runner` glue.
- Emits the edge magnitude slice (`|E-W| + |S-N|`) and the neuron’s raw/ReLU
  activations in Q8.8.
- Prints three text dashboards: edge heatmap, ReLU heatmap, and a binary firing
  mask (`#` marks active neurons).
- Optionally dumps the raw Q-values and metadata to JSON for downstream tooling.

### Patterns

| Pattern | Description |
| --- | --- |
| `cross` (default) | Bright cross on a dim background – highlights clean edge ridges. |
| `ramp` | Smooth diagonal ramp – demonstrates that gradual gradients stay near zero. |
| `checker` | High-frequency checkerboard – drives the edge detector into saturation. |
| `diag` | Diagonal stripe fallback – useful for quick regression tests. |

### Files

| File | Description |
| --- | --- |
| `neural_edge_slice_tb.v` | Fixed-point edge detector + single-layer neural combiner. |
| `run.py` | CLI wrapper that compiles, runs, parses, and renders the results. |
| `neural_edge_slice_config.vh` | Default behavioural knobs, superseded by generated headers in `build/`. |
| `configs/default.yaml` | Preset describing the demo pipeline (window, gains, circuits). |
| `build/` | Created on demand; contains the generated `neural_edge_slice.vvp`. |
| `../../rtl/circuits/` | Library of reusable primitives (`sand_circuit_edge_l1`, `sand_circuit_neuron_relu`). |

### Next steps

* Swap the synthetic patterns for images streamed in via the seed port.
* Replace the scalar neuron with a small microcode table to emulate non-linear
  classifiers or attention gates.
* Chain multiple slices (edge, sharpen, diffusion) to approximate a full
  convolutional stem using only sandbox primitives.
