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

### How to read the arguments

The behavioural harness mirrors the way the streaming RTL walks a “3D” sandbox:
the hardware still visits one 2D slice at a time, but every iteration the engine
automatically pulls the layer above/below so vertical interactions feel
continuous. The example exposes two related notions of “depth”:

- **Grid depth (`window_depth`)** – number of stacked layers processed every
  iteration. In hardware a single raster pass visits depth slices sequentially
  (layer 0, layer 1, …) yet the neighbour taps give the illusion of a 3D volume.
- **Iteration count (`iterations`)** – how many times the full stack is updated
  before the run terminates. Each iteration represents another round of
  time-multiplexed updates across the same stack, letting the field settle.

Arguments fall into a few groups (CLI flags map straight to the plusargs passed
into the testbench):

| Group | Flag / YAML key | Purpose |
| --- | --- | --- |
| Volume geometry | `--window-width`, `--window-height`, `--window-depth` (`window.width/height/depth`) | Size of the sub-volume extracted from the global sandbox grid. |
| Stimulus pattern | `--pattern` (`pattern`) | Chooses one of the procedural base patterns (core, ripple, layered, noise). |
| Timing | `--iterations` (`iterations`) | Number of sequential update passes applied to the stack. |
| Neighbour mix | `--self-gain`, `--planar-gain`, `--vertical-gain`, `--bias` (`aggregator.self/planar/vertical/bias`) | Gains and bias given to `sand_circuit_neighbor_mix` before the activation. |
| Feedback loop | `--feedback`, `--damp` (`feedback.gain/damp`) | Coupling strength from the top layer back into the bottom, and how much of the previous deviation is cancelled. |
| Bias learning | `--learning-rate`, `--target` (`learning.rate/target`) | Scales the moving-average error and sets the desired mean activation for the top slice. |
| Readout neuron | `--readout-edge`, `--readout-raw`, `--readout-bias`, `--readout-threshold` (`readout.edge/raw/bias/threshold`) | Gains and threshold for the ReLU neuron that compresses the stack into a spike map. |
| Output | `--json` | Optional path to dump the raw fixed-point grids. |

All numeric overrides expect real values in the CLI. Internally they are scaled
to thousandths (e.g. `--self-gain 0.55` → `550`) so the Verilog side can stay in
integer arithmetic.

### Example configuration / input

The default preset (`configs/default.yaml`) describes a 6×6×3 “ripple” volume and
corresponding gains:

```yaml
neural_activation_field:
  window:
    width: 6
    height: 6
    depth: 3
  pattern: ripple            # alternating rings of ±1
  iterations: 4              # redraw the full stack four times
  aggregator:
    self: 0.55               # retain just over half of the current value
    planar: 0.35             # mix in 4-neighbour average
    vertical: 0.25           # bleed from layer ±1
    bias: -0.12              # initial bias offset before adaptation
  feedback:
    gain: 0.4                # feed the top layer back into the base sheet
    damp: 0.1                # decay the old deviation each pass
  learning:
    rate: 0.12               # how aggressively the bias chases the target
    target: 0.35             # desired mean activation on the top layer
  readout:
    edge: 0.6                # weight for depth-averaged activation
    raw: 0.4                 # weight for the static stimulus
    bias: -0.1               # bias term before thresholding
    threshold: 0.3           # ReLU firing threshold
```

Running the harness with `python3 examples/neural_activation_field/run.py
--config .../default.yaml` seeds the ripple pattern, then prints one ASCII heatmap
per layer, the readout potentials, and the spike mask so you can see how the 3D
field evolves over time while still being time-multiplexed through a 2D raster.

If you want to override the “weights” on the fly, use CLI flags instead of
editing YAML. For example:

```
python3 examples/neural_activation_field/run.py \
    --pattern core --iterations 6 \
    --self-gain 0.65 --planar-gain 0.25 --vertical-gain 0.15 --bias -0.05 \
    --feedback 0.5 --damp 0.08 \
    --learning-rate 0.2 --target 0.45 \
    --readout-edge 0.7 --readout-raw 0.3 --readout-bias -0.05 --readout-threshold 0.35
```

This command keeps the same procedural stimulus but tweaks the neighbour mix
weights, feedback loop, learning rate, and readout gains without touching the
source files. The script converts each float into the fixed-point integer the
Verilog testbench expects.

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
