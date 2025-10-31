# 🏖️ The Sand(box) Project
### *A Dynamic, Concurrent, Multi-Dimensional Sandbox Engine in Verilog*

---

## Overview

**Sand(box)** is a synthesizable Verilog sandbox fabric built from tiny processing elements—**sand grains**—that exchange state with their neighbours. Parameterized grids, adaptive scheduling, and configurable rules let it emulate diffusion, fluid toys, neural cellular automata, or bespoke dataflow fabrics on FPGA or in simulation.

### Highlights
- Parametric 2D/3D grids with pointer-swapped job memory and a streaming raster engine
- Adaptive scheduler that time-multiplexes multiple sandboxes with per-job telemetry
- Rich opcode library plus a microcode LUT for custom or learned rules
- Configuration surface spanning compile-time macros, CSR registers, and YAML manifests
- Python tooling and ready-to-run demos for fast iteration

---

## Architecture Overview

```
+---------------------------------------------------+
|                    sand_top                       |
|  +---------------------------------------------+  |
|  |         sand_scheduler_dynamic              |  |
|  |  +---------------------------------------+  |  |
|  |  |        sand_engine_raster            |  |  |
|  |  |   (single-port raster update)        |  |  |
|  |  +--------------------+------------------+  |  |
|  |                       |                     |  |
|  +-----------------------v---------------------+  |
|             sand_jobmem2p (plane A/B)            |
+---------------------------------------------------+
```

| Module | Role |
| :-- | :-- |
| `rtl/sand_defs.vh` | Global parameter map for widths, grid geometry, job count, CSR layout, and default adaptive knobs. |
| `rtl/sand_math.vh` | Fixed-point helpers (saturating add/sub, mul/div, rounding) reused by the PE and raster engine. |
| `rtl/sand_pe.v` | Processing element (one grain). Evaluates opcodes, blends neighbours, consults microcode. |
| `rtl/sand_engine_raster.v` | Streams the grid through a single-port ALU, reports activity/cycle telemetry. |
| `rtl/sand_scheduler_dynamic.v` | Adaptive round-robin controller with plane flips, windowing, and per-job step budgets. |
| `rtl/sand_jobmem2p.v` + `rtl/bram_tdp_wrap.v` | Dual-plane memory with O(1) pointer swaps; replace wrapper with vendor RAM. |
| `rtl/circuits/` | Reusable combinational shims (edge detector, ReLU, neighbour mix, micro-LUT activation). |
| `rtl/legacy/` | Reference parallel mesh (`sand_grid`, `sand_scheduler`, `sand_jobmem`) kept for comparison. |

---

## How the Engine Runs

- Jobs are queued round-robin; the scheduler gathers telemetry (`frame_activity`, `frame_cycles`) and stretches or shrinks step budgets on the fly.
- Each raster pass reads from one BRAM plane, computes the update inside `sand_pe`, and writes the result into the opposite plane before toggling the pointer bit.
- Opcodes cover diffusion, Laplacian sharpening, water flux, pressure relaxation, min/max morphology, gradient detection, programmable mixes, and a 16-entry microcode LUT.
- Optional diagonals, above/below neighbours, per-job windows, and adaptive thresholds are driven from CSRs.

---

## Configuration Surfaces

- **Compile-time:** Edit `rtl/sand_defs.vh` to pick data width (`DATA_W`/`FRAC_W`), grid geometry (`WIDTH`, `HEIGHT`, `DEPTH`), job count, and default adaptive limits. `rtl/sand_math.vh` centralises arithmetic behaviour (saturation, rounding).
- **CSR bus:** `sand_top` exposes a simple register file for host control. Key registers include:

  | CSR macro | Purpose |
  | :-- | :-- |
  | `CSR_RULE_JOB`, `CSR_RULE_OP`, `CSR_RULE_CONSTA…D` | Select job, opcode, and four fixed-point coefficients used by `OP_MIX` and friends. |
  | `CSR_FLAGS` | Enables diagonals and microcode addressing mode inside the PE. |
  | `CSR_MICRO_BASE + N` | 16-entry microcode LUT (hot-swappable while the engine runs). |
  | `CSR_ADAPT_CTRL`, `CSR_ADAPT_THRESH_{LO,HI}`, `CSR_ADAPT_CAPACITY` | Adaptive scheduler enable, thresholds, and optional cycle cap. |
  | `CSR_ADAPT_STATUS_SEL`, `CSR_ADAPT_STATUS`, `CSR_ADAPT_BUDGET` | Per-job telemetry view (activity/cycles and current step budget). |
  | `CSR_UNIT_*` | Configurable water-flux/pressure/backprop primitives (thresholds, gains, friction). |

- **Seeding:** A dedicated port writes arbitrary job/layer/cell tuples for initial conditions or mid-run resets.

---

## Tooling

- `python3 tools/sand_runner.py` — convenience wrapper to compile (`iverilog`) and run (`vvp`) simulations.
- `python3 tools/sand_configurator.py --config examples/<demo>/configs/<name>.yaml` — expands YAML/JSON presets into Verilog headers plus circuit manifests for example harnesses.
- `python3 -m tools.sand_dynamic_configurator <command>` — kernel-style feature configurator that resolves dependencies, enforces resource budgets, and emits `build_plan.json` + `sand_dynamic_types.vh`.

---

## Examples

- `examples/galton_board/` — deterministic + stochastic Galton board. Run `python3 examples/galton_board/run.py` to compile and inspect the distribution.
- `examples/neural_edge_slice/` — edge detector + ReLU shim driven from YAML. Run `python3 examples/neural_edge_slice/run.py --config examples/neural_edge_slice/configs/default.yaml`.
- `examples/neural_activation_field/` — 3D neighbour mix with optional activation bypass and adaptive bias/readout. Run `python3 examples/neural_activation_field/run.py --config examples/neural_activation_field/configs/default.yaml`.

Each script generates a build directory containing the auto-produced headers and source manifests before launching simulation.

---

## Customising Behaviour

- **Opcodes:** `sand_pe` covers diffusion, Laplacian, sharpen, edge magnitude, programmable mix, water flux, pressure relaxation, backprop, and microcode lookups. Mix operations consume four CSR-configurable coefficients; Laplacian/min/max automatically include vertical neighbours.
- **Microcode LUT:** Use `CSR_MICRO_BASE` to stream 16 Q-format entries that encode bespoke activations, symbolic rules, or learned responses. The default index combines opcode/self bits but can be reassigned inside the RTL if you prefer average-based addressing.
- **Unit weights:** `CSR_UNIT_*` registers describe capability, directional weights, and friction for water-flux/pressure primitives. Pair them with the adaptive scheduler to prioritise hot sandboxes—the streaming engine and legacy `sand_pe` now honour the tuple whenever `unit_flux_enable` is asserted (and fall back to the classic constant-driven flow otherwise).
- **Numeric formats:** Adjust `DATA_W`/`FRAC_W`, enable saturation/rounding macros, or swap in alternative arithmetic (float, bfloat16, packed fixed-point) via the helper templates in `sand_math.vh`.

---

## Integration Guide

- **Simulation loop:** Instantiate `sand_top` in a testbench, drive CSR writes through small helper tasks, seed BRAM via the seed port, and step the clock. Examples show minimal scaffolding for iverilog/vvp.
- **FPGA bring-up:** Swap `rtl/bram_tdp_wrap.v` for vendor-specific true dual-port RAM, keep the two-plane pointer swap, connect the CSR bus to your host interface (AXI-Lite, simple MMIO, soft CPU), and monitor `job_done` plus adaptive status registers.
- **Performance knobs:** Narrow the active window via CSR offsets, tweak adaptive thresholds, or extend the raster engine with extra read ports if you need >1 cell/clk throughput.

---

## Resources

- `AI_REFERENCE.md` — quick repository map, configuration notes, and workflow reminders.
- `studies/papers/waterfall-arithmetic-unit/WaterfallArithmeticUnit.en.md` — related “Waterfall Arithmetic Unit” architecture that inspired the streaming fabric.
- `studies/notes.md` — ongoing design notes and experiments.
- `studies/scenario_presets.md` — curated CSR/seeding presets for diffusion, percolation, CA, and neural demos.
- `examples/<name>/README.md` — scenario-specific documentation and configuration tips.

---

## License & Credits

MIT License © 2025 Riccardo Cecchini (Gecko’s Ink).  
Concept, RTL, and documentation composed with help from ChatGPT 5. Inspired by cellular automata, reaction-diffusion systems, neural cellular automata research, and dataflow compute fabrics.
