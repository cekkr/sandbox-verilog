# Neural Activation Field Example

This behavioural demo exercises the sandbox project’s 3D neighbour logic to
model a **neural-ish activation field**: a small stack of layers that blend
planar and vertical neighbours, pass the result through a soft-saturating
activation, feed back the top layer into the base stimulus, and learn a bias
term that nudges the field toward a target activation level. A lightweight
readout neuron then compresses the 3D state into a spike map, highlighting
regions that consistently excite the stack.

The Verilog testbench (`neural_activation_field_tb.v`) keeps the arithmetic
aligned with the main RTL using `sand_defs.vh` and the shared circuit library:

- `sand_circuit_neighbor_mix` performs 3D weighted averaging with programmable
  self/planar/vertical gains plus a bias.
- `sand_circuit_activation_softsign` applies a smooth softsign non-linearity to
  emulate a tanh-like activation without LUT lookups.
- `sand_circuit_neuron_relu` turns the depth-collapsed response into a
  thresholded ReLU spike map.

The Python runner generates a config header from YAML/JSON, compiles the
testbench with Icarus Verilog, executes the simulation, and renders the 3D
activation volume as ASCII heatmaps.

```
python3 examples/neural_activation_field/run.py \
    [--config configs/default.yaml] \
    [--window-width 8] [--window-height 8] [--window-depth 3] \
    [--pattern core|ripple|layered|noise] \
    [--iterations 6] \
    [--self-gain 0.6] [--planar-gain 0.3] [--vertical-gain 0.2] \
    [--bias -0.1] [--feedback 0.45] [--damp 0.08] \
    [--learning-rate 0.18] [--target 0.4] \
    [--readout-edge 0.5] [--readout-raw 0.5] \
    [--readout-bias -0.05] [--readout-threshold 0.25] \
    [--json activation.json]
```

- Parses the optional YAML/JSON config (`configs/default.yaml` by default) and
  writes a generated `neural_activation_field_config.vh` header in `build/`.
- Compiles `neural_activation_field_tb.v` together with the required circuits
  from `rtl/circuits/`.
- Streams the simulation output, collecting per-iteration telemetry, the final
  activation volume, and the readout neuron responses.
- Prints ASCII heatmaps for each layer, plus the readout potentials and spike
  mask. Optionally exports the raw fixed-point values to JSON.

### Patterns

| Pattern | Description |
| --- | --- |
| `core` | Spherical hotspot with vertical fall-off, ideal for testing diffusion. |
| `ripple` | Radial rings that alternate excitation/inhibition, pushing the bias learner. |
| `layered` | Monotonic ramp across depth and height to highlight vertical coupling. |
| `noise` | Deterministic pseudo-random stimulus for stress-testing adaptation. |

### Files

| File | Description |
| --- | --- |
| `neural_activation_field_tb.v` | 3D blend/activation/feedback pipeline with bias adaptation. |
| `run.py` | CLI wrapper that compiles the harness, runs the sim, and renders results. |
| `neural_activation_field_config.vh` | Seed defaults, overridden by generated headers in `build/`. |
| `configs/default.yaml` | Preset volume parameters and gains. |
| `build/` | Created on demand; holds the generated header and compiled `neural_activation_field.vvp`. |
| `../../rtl/circuits/` | Circuit primitives reused by the testbench. |

### Next steps

- Swap the behavioural softsign for the hardware microcode LUT to mirror the
  streaming PE activation.
- Expose per-layer feedback gains to emulate skip connections or attention
  maps.
- Drive the example from real sensor frames (or an image) using the seed port
  instead of synthetic stimuli.

