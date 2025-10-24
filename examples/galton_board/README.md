# Galton Board Example

This example models a discrete Galton board on top of the sandbox project’s
fixed-point conventions. The “sand” represents the programmable **weights** of
each peg – how much momentum is steered left or right – while the “balls” (or
water molecules) are transient mass packets that flow through those weights.

The Verilog testbench (`galton_board_tb.v`) performs a pure combinational walk
through the board. Every step splits the current row’s mass according to
left/right weights (`Q8.8` format), accumulates it into the next row, and keeps
track of the remaining straight-through component. The weights are constant per
row in this demo, but the arrays are explicit so that future work can swap in
per-peg bias maps or hook the data to a live sandbox fabric.

The companion Python script orchestrates the flow:

```
python3 examples/galton_board/run.py [--left 500] [--right 500]
                                     [--board-width 15] [--board-height 16]
                                     [--samples 1024] [--json output.json]
```

- Compiles the Verilog testbench with **Icarus Verilog** (see `tools/sand_runner.py`).
- Runs the simulation with plusargs derived from the CLI flags.
- Parses the `GALTON.bin[…]` traces and converts them from `Q8.8` to floating
  point probabilities (“linear” distribution).
- Optionally draws additional random balls (`--samples`) to illustrate the
  emergent Gaussian histogram using the deterministic weight distribution.
- Optionally emits a JSON payload (`--json`) holding both the analytic weights
  and the sampled counts.

Key flags:

* `--left` / `--right`: thousandths (0–1000) of mass that a peg pushes left or
  right. The remainder is carried straight through the peg.
* `--board-width` / `--board-height`: active window inside the broader sandbox
  grid. Defaults match the README diagrams (15×16).
* `--samples`: number of Monte Carlo balls to draw from the deterministic
  distribution (set to `0` to skip sampling).
* `--json`: capture run metadata + distributions for reuse in notebooks or
  host-side tooling.

### Files

| File | Description |
| --- | --- |
| `galton_board_tb.v` | Fixed-point Galton board evolution using integer arrays.
| `run.py` | CLI wrapper that compiles, runs, parses, and optionally samples.
| `build/` | Created on demand; holds the generated `galton_board.vvp` binary.

The example only depends on `iverilog`/`vvp` and Python ≥3.8. No synthesis tools
are required.

### Extending the demo

* Swap the constant weights for a CSV/JSON map read in by the testbench to model
  arbitrary bias patterns.
* Tie the `weight_left/right` arrays to sandbox CSR writes to exercise the live
  Verilog engine instead of the behavioural proxy.
* Emit UART frames from the testbench (or hook up a real transport) to feed
  distributions into downstream analytics.
