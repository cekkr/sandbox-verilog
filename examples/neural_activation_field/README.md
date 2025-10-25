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
- `sand_circuit_activation_micro_lut` applies a microcode-based activation that mirrors the streaming processing element.
- `sand_circuit_neuron_relu` turns the depth-collapsed response into a
  thresholded ReLU spike map.

The Python runner generates a config header from YAML/JSON, compiles the
testbench with Icarus Verilog, executes the simulation, and renders the 3D
activation volume as ASCII heatmaps.

## "Sandbox" vs "Mobile Sand" vs "Solid Sandbox"

This example can be run in three different modes, each representing a different stage in the development and deployment of a neural network on the sandbox hardware:

*   **"Sandbox" (Training/Exploration):** This is the default mode of operation. In this mode, the testbench uses behavioural models for the different components of the neural network. This allows for rapid prototyping and exploration of different network architectures and parameters. The `run.py` script is used to compile and run the simulation, and to visualize the results.

*   **"Mobile Sand" (Hardware-in-the-loop):** In this mode, the behavioural models are replaced with their hardware-equivalent counterparts. This allows for more accurate simulation of the neural network's behaviour on the target hardware. This mode is useful for verifying the correctness of the hardware implementation and for fine-tuning the network parameters.

*   **"Solid Sandbox" (Inference):** This is the final stage, where the trained neural network is deployed on the sandbox hardware for inference. In this mode, the network is fed with real sensor data, and the output is used to drive other components of the system.

## Training vs. Inference

### Training

During training, the goal is to learn the optimal weights for the network. This is done by providing the network with a set of training data and adjusting the weights to minimize the error between the network's output and the desired output. In this example, the `learning_rate` and `target` parameters are used to control the training process.

To train the network, you need to provide a dataset. The dataset is a hex file containing the input data. The file should contain one hexadecimal value per line, in Q8.8 format. You can create your own dataset or use one of the provided patterns.

```
# Create a dummy dataset
$ echo "0100" > dataset.hex
$ echo "0200" >> dataset.hex
$ echo "0300" >> dataset.hex
$ echo "0400" >> dataset.hex

# Train the network
python3 examples/neural_activation_field/run.py \
    --image-file dataset.hex \
    --iterations 10 \
    --learning-rate 0.2 --target 0.45 \
    --json build/training_results.json
```

This command will run the simulation for 10 iterations with a learning rate of 0.2 and a target activation of 0.45. The final state of the network, including the learned bias, will be saved to `build/training_results.json`.

### Inference

Once the network has been trained, it can be used for inference. During inference, the network is used to make predictions on new data. In this example, the `--image-file` argument is used to provide the network with an input image. The `--learning-rate` is set to 0 to prevent the network from further learning.

```
python3 examples/neural_activation_field/run.py \
    --image-file <path_to_image.hex> \
    --learning-rate 0 \
    --config build/training_results.json
```

This command will load the trained network from `build/training_results.json`, run the simulation with the input image, and output the results.

## Driving the example with an image

To drive the example with an image, you can use the `--image-file` command-line argument to specify the path to a hex file containing the image data. The hex file should be a plain text file with one hexadecimal value per line. The values should be in Q8.8 format.

For example, to load a 2x2 image, the `image.hex` file would look like this:

```
0100
0200
0300
0400
```

This would initialize the `base_field` with the following values:

```
base_field[0][0][0] = 16'h0100;
base_field[0][0][1] = 16'h0200;
base_field[0][1][0] = 16'h0300;
base_field[0][1][1] = 16'h0400;
```

The "water" (activation) flows from the `base_field` upwards through the layers. The `base_field` can be thought of as the initial water level, and the weights of each LUT (look-up table) in the `sand_circuit_activation_micro_lut` as a series of gates that control the flow of water. The feedback mechanism allows water from the top layer to flow back to the bottom, creating a recurrent connection.

## Per-layer feedback gains

To specify per-layer feedback gains, you can use the `--feedback-l<n>-pct` command-line argument, where `<n>` is the layer number. For example, to set the feedback gain for layer 0 to 50%, you would use the following argument:

```
python3 examples/neural_activation_field/run.py \
    --feedback-l0-pct 50 \
    [--config configs/default.yaml] \
    ...
```

## How to read the arguments

The behavioural harness mirrors the way the streaming RTL walks a “3D” sandbox:the hardware still visits one 2D slice at a time, but every iteration the engine
automatically pulls the layer above/below so vertical interactions feel
continuous. The example exposes two related notions of “depth”:

- **Grid depth (`window_depth`)** – number of stacked layers processed every iteration. In hardware a single raster pass visits depth slices sequentially (layer 0, layer 1, …) yet the neighbour taps give the illusion of a 3D volume.
- **Iteration count (`iterations`)** – how many times the full stack is updated before the run terminates. Each iteration represents another round of time-multiplexed updates across the same stack, letting the field settle.

Arguments fall into a few groups (CLI flags map straight to the plusargs passed into the testbench):

| Group | Flag / YAML key | Purpose | 
| --- | --- | --- |
| Volume geometry | `--window-width`, `--window-height`, `--window-depth` (`window.width/height/depth`) | Size of the sub-volume extracted from the global sandbox grid. | 
| Stimulus pattern | `--pattern` (`pattern`) | Chooses one of the procedural base patterns (core, ripple, layered, noise). | 
| Stimulus pattern | `--image-file` (`image_file`) | Path to a hex file containing the image data. | 
| Timing | `--iterations` (`iterations`) | Number of sequential update passes applied to the stack. | 
| Neighbour mix | `--self-gain`, `--planar-gain`, `--vertical-gain`, `--bias` (`aggregator.self/planar/vertical/bias`) | Gains and bias given to `sand_circuit_neighbor_mix` before the activation. | 
| Feedback loop | `--feedback-l<n>-pct`, `--damp` (`feedback.gain/damp`) | Coupling strength from each layer back into the bottom, and how much of the previous deviation is cancelled. | 
| Bias learning | `--learning-rate`, `--target` (`learning.rate/target`) | Scales the moving-average error and sets the desired mean activation for the top slice. | 
| Readout neuron | `--readout-edge`, `--readout-raw`, `--readout-bias`, `--readout-threshold` (`readout.edge/raw/bias/threshold`) | Gains and threshold for the ReLU neuron that compresses the stack into a spike map. | 
| Output | `--json` | Optional path to dump the raw fixed-point grids. | 

All numeric overrides expect real values in the CLI. Internally they are scaled to thousandths (e.g. `--self-gain 0.55` → `550`) so the Verilog side can stay in integer arithmetic.

### Example configuration / input

The default preset (`configs/default.yaml`) describes a 6×6×3 “ripple” volume and corresponding gains:

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
    --feedback-l0-pct 50 --feedback-l1-pct 20 --feedback-l2-pct 10 --damp 0.08 \
    --learning-rate 0.2 --target 0.45 \
    --readout-edge 0.7 --readout-raw 0.3 --readout-bias -0.05 --readout-threshold 0.35
```

This command keeps the same procedural stimulus but tweaks the neighbour mix
weights, feedback loop, learning rate, and readout gains without touching the
source files. The script converts each float into the fixed-point integer the
Verilog testbench expects.

### Large grids, external datasets, and weight dumps

The behavioural runner sticks to small windows so the ASCII dashboards stay
readable, but the same plumbing works for larger sandboxes (e.g. 64×64×8):

1. Describe the region you want to simulate in a config/YAML file:

   ```yaml
   neural_activation_field:
     window: { width: 64, height: 64, depth: 8 }
     pattern: core  # or "external" if you plan to load data yourself
     iterations: 6
     aggregator: { self: 0.5, planar: 0.3, vertical: 0.2, bias: 0.0 }
     feedback:   { gain: 0.2, damp: 0.05 }
     learning:   { rate: 0.08, target: 0.4 }
     readout:    { edge: 0.6, raw: 0.4, bias: 0.0, threshold: 0.35 }
   ```

2. Provide the initial state (and optional per-cell weights) as raw files. The
   testbench consumes plain text or JSON:

   - **Stimulus:** CSV of Q8.8 integers per layer (one file per depth plane) or
     a single JSON map:  
     ```json
     {
       "stimulus_q": [[[0, 128, ...], ...], ...],  // depth × height × width
       "frac_bits": 8
     }
     ```
   - **Custom gains:** optional JSON block containing cell-specific gains if the
     uniform coefficients in the CLI aren’t enough.

   Extend `run.py` by pointing `--config` to the new YAML and using `--json` to
   capture the simulation output:
   ```
   python3 examples/neural_activation_field/run.py \
       --config configs/large64.yaml \
       --json build/runs/large64_results.json
   ```

3. Inspect the generated JSON. The runner already emits:

   ```json
   {
     "activations_q": [[[...]]],  // final activation volume (fixed-point)
     "readout_raw_q": [[...]],
     "readout_relu_q": [[...]],
     "readout_fire": [[0|1]],
     "config": { "agg": {...}, "ctrl": {...}, "readout": {...} },
     "iterations": { "0": {"bias_q": ...}, ... }
   }
   ```

   Use this as training data, or convert it into weight updates for a real FPGA
   run. If you plan to do iterative training, script a loop that:
   (a) launches the simulation, (b) reads `activations_q`, (c) computes new
   weights, and (d) rewrites the YAML/JSON inputs for the next pass.

4. For complete offline workflows, you can add optional CLI flags (e.g.
   `--stimulus-json`, `--weights-json`) that read structured inputs and seed the
   Verilog arrays directly. The deliberate split between YAML (human-friendly
   config) and JSON (machine-friendly volumes) makes it easy to evolve toward
   a proper training/export pipeline without changing the core testbench.

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

- [x] Swap the behavioural softsign for the hardware microcode LUT to mirror the
  streaming PE activation.
- [x] Expose per-layer feedback gains to emulate skip connections or attention
  maps.
- [x] Drive the example from real sensor frames (or an image) using the seed port
  instead of synthetic stimuli.
