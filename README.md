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
| `rtl.yaml/` | YAML mirror of synthesizable RTL (minus `rtl/legacy/`) for Python-side exploration and regeneration. |
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
- `python3 tools/verilog_yaml_bridge.py export --rtl-root rtl --yaml-root rtl.yaml` — mirrors synthesizable RTL into YAML (and `restore` rebuilds the Verilog).

### RTL YAML mirror

- `tools/verilog_yaml_bridge.py` consumes the contents of `rtl/` (excluding `rtl/legacy/`) and writes structured YAML artefacts into `rtl.yaml/`.
- Modules that fit within PyVerilog's syntax support are exported as full ASTs (`kind: verilog_module`) so Python tooling can round-trip edits back into Verilog.
- For complex SystemVerilog blocks (`sand_engine_raster`, `sand_pe`, `sand_scheduler_dynamic`) the bridge currently falls back to a header summary plus the original body text (`kind: verilog_module_fallback`) because PyVerilog cannot parse their block-scoped declarations yet. The bridge still preserves their includes and interface metadata.
- Run `python3 tools/verilog_yaml_bridge.py restore` to regenerate RTL from the YAML mirror after editing.

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

---


## Overview

**The Sand Project** is a **parametric, self-organizing grid** of tiny processing elements — called **sand grains** — that communicate with their neighbors and evolve over time according to configurable math rules.
Each grain behaves like a microscopic compute node that can interact, absorb, diffuse, and transform information — very much like a simulation of *sand and water*, or, at a higher level, a primitive **machine-learning cellular automaton**.

The system is implemented fully in **synthesizable Verilog**, and designed to:

* Scale to 2D or 3D grids (limited only by FPGA resources)
* Allow **dynamic configuration** of dimensions, math behavior, and topology
* Support **multiple “sandboxes” (jobs)** time-multiplexed on the same hardware
* Enable **concurrent communication** between units without race conditions
* Behave conceptually like a **tiny distributed learning fabric**

---

## 🌐 Conceptual Background

A “**sandbox**” in this context is not just a simulation:
It’s a miniature world where every grain of sand holds a **state** and **rule of interaction**.

Each unit:

* Knows about its **neighbors** (north, south, east, west, optionally diagonals)
* Updates itself using **mathematical operations** (sum, average, diffusion, min, max, etc.)
* Can follow **user-defined rules** through a small **microcode table**
* Evolves **in parallel** with all others, in emergent patterns or stable flows

When seen in 3D, each **layer** of sand passes information to the next, like **water percolating** or **neurons activating in depth**.
The entire structure behaves a bit like a **machine-learning model** — one that learns by local interactions rather than global training.

---

## ⚙️ Architecture

The project is organized into clean, layered modules:

| Module                      | Description                                                                                                                                                                |
| :-------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`rtl/sand_defs.vh`**          | Global parameter file — defines word widths, grid size, number of jobs, math opcodes, and CSR addresses. Edit this first to customize your FPGA target.                    |
| **`rtl/sand_math.vh`**          | Saturating/rounding fixed-point helpers used by the PE and raster engine.                                                                                                  |
| **`rtl/circuits/`**             | Reusable combinational building blocks (edge detectors, neural shims, etc.) that examples can stitch together without rewriting Verilog.                                   |
| **`rtl.yaml/`**                 | YAML mirror of synthesizable RTL (excluding legacy) for Python-side introspection and regeneration.                                                                         |
| **`rtl/sand_pe.v`**             | The *Processing Element* (one grain). Reads its 4–8 neighbors and applies an operation (sum, diffusion, clamp, etc.) or a user-defined microcode rule.                    |
| **`rtl/sand_scheduler_dynamic.v`** | Adaptive round-robin scheduler. Tracks per-job activity, selects step budgets, and drives the pointer-swap raster engine (`sand_engine_raster`).                         |
| **`rtl/sand_engine_raster.v`** | Streaming single-port engine that walks the grid cell-by-cell, produces activity metrics, and writes results into the opposite memory plane.                          |
| **`rtl/sand_jobmem2p.v`**     | Two-plane dual-port job memory. Each job/layer owns {read,write} planes and a plane-select bit toggled by the scheduler.                                              |
| **`rtl/sand_top.v`**            | Integration wrapper exposing the CSR bus, seeding port, and the adaptive core.                                                                                            |
| **`rtl/bram_tdp_wrap.v`**   | Portable true dual-port BRAM wrapper (vendor-inferable).                                                                                                                   |
| **`rtl/legacy`** / (**`sand_grid.v` / `sand_scheduler.v` / `sand_jobmem.v`**) | Legacy fully-parallel path kept for reference (instantiates an in-core `WIDTH × HEIGHT` PE mesh).                                             |

---

## 🧠 Conceptual Flow

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

Each **tick** performs:

1. The scheduler selects a job and a layer
2. The scheduler points the raster engine at the correct job/layer plane
3. Cells are streamed through the ALU; the write plane receives the new values
4. The plane bit toggles (pointer swap) instead of copying buffers
5. Adaptive logic decides whether to run another step or rotate to the next job/layer

---

## 🔧 Configuration

All parameters are centralized in [`sand_defs.vh`](sand_defs.vh):

| Parameter                  | Meaning                                              |
| :------------------------- | :--------------------------------------------------- |
| `DATA_W`                   | Data width of each cell (default 16-bit fixed-point) |
| `FRAC_W`                   | Fractional bits if fixed-point math is used          |
| `WIDTH`, `HEIGHT`, `DEPTH` | Grid dimensions                                      |
| `N_JOBS`                   | Number of concurrent sandboxes time-sliced           |
| `STEPS_PER_SLICE`          | How many steps each job runs before switching        |
| `USE_DIAGONALS`            | Enable 8-neighborhood mode                           |
| `CSR_*`                    | Control/Status register map                          |
| `OP_*`                     | List of ALU opcodes (sum, average, diffusion, etc.)  |

You can freely change these before synthesis — the design is **fully parametric**.

Additional rule coefficients are mapped at `CSR_RULE_CONSTC` and `CSR_RULE_CONSTD` and pair with the new programmable mix (`OP_MIX`), giving you four independent fixed-point knobs per rule.

### Unit Dynamics & Windows

The enhanced **unit** pipeline lets you bias each layer like a Galton board: you can stream weighted flux from the top, relax pressure iteratively, or fold in a backprop-style correction while the raster engine walks the grid. Each directional weight now behaves like a three-component tuple that governs how mass moves between neighbors:

- `capability` — how much the local grain can hold before it starts to spill (mapped to the saturation threshold).
- `channel` — how wide the conduit to the neighbor is; larger values let more mass cross in a single step.
- `friction` — how much opposing pressure must be overcome to initiate or maintain flow; this is derived from the reverse/pressure coefficients.

The water and pressure opcodes evaluate the tuple on both sides of an edge, so the effective transfer per step becomes:

```
flux = (min(cap_a, cap_b) * channel) - friction_diff
```

where `friction_diff` compares the local friction term with the neighbor’s counter-pressure so the dominant side dictates the net direction.

Key CSRs that drive this behaviour:

| CSR | Description |
| :-- | :---------- |
| `CSR_UNIT_CTRL` | Bit0 enables flux, bits1-2 route overflow (up/down), bit3 optionally forces diagonal sampling for pressure, bits15:8 set the pressure iteration budget (1‥32) |
| `CSR_UNIT_WINDOW_WH` / `CSR_UNIT_WINDOW_OFFSET` | Per-job active window (width/height and X/Y offset). Select the target job with `CSR_JOB_SELECT` before writing. |
| `CSR_UNIT_STATUS_WINDOW` / `CSR_UNIT_STATUS_OFFSET` | Read back the sanitized window settings for the selected job. |
| `CSR_UNIT_FLUX_*` | Directional weights (`TOP`, `BOTTOM`, `SIDE`, `RETAIN`, `PREV`), a saturation threshold, and fractional coefficients for overflow feedback. |
| `CSR_UNIT_PRESSURE_GAIN` | Fixed-point exchange rate multiplied during each pressure iteration. |
| `CSR_UNIT_BACKPROP_*` | Learning-rate, neighbour gain, and decay factors for the gradient update primitive. |

Program the tuple by pairing `CSR_UNIT_FLUX_THRESHOLD` with the directional weights for capability/channel, and use `CSR_UNIT_FLUX_REVERSE_{TOP,BOTTOM}` together with `CSR_UNIT_PRESSURE_GAIN` to model friction and counter-pressure.
Bits 1 and 2 of `CSR_UNIT_CTRL` gate whether the reverse coefficients participate as friction; clear them to remove resistance on the corresponding vertical edges.
Legacy `sand_pe` now mirrors the same tuple-driven flow whenever `unit_flux_enable` is asserted, keeping the fully parallel fabric in lock-step with the streaming raster engine. Clear the bit to retain the historical constA/constB/constC/constD behaviour.

**How the new opcodes map to the knobs**

- `OP_WATER_FLUX` consumes the directional weights and threshold, mixes in `constB` as the vertical/backfeed term, and bleeds overflow according to the up/down coefficients.
- `OP_PRESSURE` executes as many micro-iterations as requested, multiplying the difference between the running pressure and the neighbour average by `CSR_UNIT_PRESSURE_GAIN`.
- `OP_BACKPROP` treats `constB` as the target signal, `CSR_UNIT_BACKPROP_LR` as the learning rate, and nudges the cell using the neighbour coupling (`NEIGH`) and decay values.

Use window offsets to shrink the active region when a model only occupies part of the fabric: the raster engine will skip untouched cells, saving cycles and bandwidth without requiring you to resize the underlying BRAM planes.

---

## 🧩 The Processing Element (`sand_pe`)

Each PE runs the core update rule:

```
next = f(self, neighbors, constA…constD, opcode)
```

### Supported Operations

| Opcode            | Behavior                                                                 |
| :---------------- | :----------------------------------------------------------------------- |
| `OP_SUM_NBRS`     | Sum of planar neighbors (4 or 8 depending on `use_diagonals`)            |
| `OP_AVG_NBRS`     | Average of planar neighbors                                              |
| `OP_ADD_CONST`    | Add constant A                                                           |
| `OP_SUB_CONST`    | Subtract constant A                                                      |
| `OP_MUL_CONST`    | Multiply by constant A                                                   |
| `OP_DIV_CONST`    | Divide by constant A                                                     |
| `OP_DIFFUSION`    | `self + k*(avg - self)` (soft diffusion)                                 |
| `OP_MIN / OP_MAX` | Minimum or maximum across planar + vertical neighbors                    |
| `OP_CLAMP`        | Clamp between constA..constB                                             |
| `OP_WATER_FLUX`   | Weighted water flux blending + overflow bleed                            |
| `OP_PRESSURE`     | Iterative pressure/exchange relaxation                                   |
| `OP_BACKPROP`     | Single-step gradient update toward target                                |
| `OP_LAPLACIAN`    | 6-neighbor Laplacian (`N+S+E+W+above+below - 6*self`)                   |
| `OP_SHARPEN`      | Unsharp mask using Laplacian: `self - constA * laplacian`                |
| `OP_EDGE`         | Gradient magnitude `|e-w| + |s-n|`                                       |
| `OP_MIX`          | Programmable mix `a*self + b*avg + c*(planar sum + vertical) + d`        |
| `OP_MICRO`        | Look up a user-defined rule from a 16-entry LUT                          |

`OP_MIX` consumes four fixed-point coefficients sourced from `CSR_RULE_CONSTA…CONSTD`, letting you blend the current value, the neighbor average, the aggregated (planar + vertical) sum, and a constant bias in one pass. Vertical neighbors (`above_in`/`below_in`) are now available in the PE and the raster engine fetches them automatically every cell, so Laplacian, Min/Max, and mix operations react to layer-to-layer coupling out of the box.

When `unit_flux_enable` is high the flux/pressure/backprop paths pull the `{capability, channel, friction}` tuple directly from `CSR_UNIT_*`, apply per-edge friction (top/bottom honour the overflow coefficients, planar/diagonal flows reuse `CSR_UNIT_PRESSURE_GAIN`), and add the previous-layer feedback tap. If the bit is low the legacy const-driven implementation remains in place, so existing sandboxes stay functional while newer ones gain the richer tuple semantics.

### Microcode LUT

You can define a 16-entry lookup table (`micro_lut`) via CSR writes.
It lets you encode small nonlinear or symbolic rules (e.g., thresholds, Boolean masks, learned coefficients).
Entries may now be rewritten on the fly while the engine is running, which makes online/ML-style adaptation loops straightforward—just stream incremental updates through `CSR_MICRO_BASE + index`.

---

## 🧭 Scheduler and Jobs

The **scheduler** allows multiple independent “sand worlds” to coexist on the same FPGA.

Each **job** has:

* Its own **state memory** (`sand_jobmem`)
* Its own **parameters and constants**
* A number of **layers** (`DEPTH`) if 3D simulation is used

The scheduler performs:

```
for job in jobs:
  for layer in depth:
    LOAD layer → RUN N steps → STORE layer
```

Jobs are rotated in a round-robin fashion.
This mechanism lets the same hardware simulate many environments concurrently.

---

## 🧮 Mathematical Concurrency and Safety

To avoid race conditions between cells updating each other:

* The design uses **ping-pong buffers** (read/write separation per tick)
* Each PE only reads from the **previous** buffer and writes to the **next**
* Boundaries are replicated (you can change to wrap or clamp)
* Time-slicing guarantees that only one sandbox writes to memory at a time

This makes the engine fully **deterministic**, yet spatially **parallel**.

---

## 🪜 From 2D to 3D

A 3D simulation is just a stack of 2D grids:

```
Layer 0  ←  input / surface
Layer 1  ←  receives from 0
Layer 2  ←  receives from 1
...
```

Between layers, the scheduler can propagate data (e.g., “gravity” effects).
The PE now natively samples the layer above and below the current cell during every raster pass, so 3D diffusion/sharpening rules and min/max morphology span the full stack without additional glue.

---

## 💡 Example Ideas

* **Cellular automata:** Game of Life variants, diffusion, erosion
* **Fluid or sand simulation:** vertical propagation, viscosity rules
* **Neural primitives:** local weighted sum + activation via microcode
* **Learning experiments:** evolving LUTs or adaptive constants
* **Procedural textures:** generating evolving 2D/3D maps in hardware

---

## 🔌 Integration and CSR Interface

`sand_top` exposes a **simple CSR bus** for configuration and monitoring:

| Address      | Description                                   |
| :----------- | :-------------------------------------------- |
| `0x00`       | Select active job                             |
| `0x04`       | Opcode                                        |
| `0x08`       | Const A                                       |
| `0x0C`       | Const B                                       |
| `0x34`       | Const C (mix coefficient)                     |
| `0x38`       | Const D (mix bias)                            |
| `0x10`       | Flags (bit0: diagonals, bit1: microcode mode) |
| `0x14`       | Status (`[0]=busy`, `[N_JOBS:1]=job_done`)    |
| `0x40..0x4F` | Microcode table entries                       |

Additionally, a **seeding interface** allows you to preload any job/layer/cell with initial data (useful for loading images, maps, or learned weights).

---

## 🧰 Building and Simulation

### 1. Synthesize on FPGA

* Set your desired parameters in `sand_defs.vh`
* Replace `bram_dp.v` with your FPGA vendor’s true dual-port BRAM primitive
* Instantiate `sand_top` in your top-level HDL or SoC wrapper
* Connect CSR lines to a soft CPU (MicroBlaze, PicoRV32, etc.) or AXI-Lite bridge

### 2. Simulate in a testbench

A minimal simulation might look like:

```verilog
initial begin
    rst = 1;
    #10 rst = 0;
    // write constants and opcodes through CSR
    csr_write(`CSR_RULE_OP, `OP_DIFFUSION);
    // seed initial data
    seed_cell(0, 0, 0, 16'h1000);
    // run for a while
    repeat (1000) @(posedge clk);
end
```

You can watch the evolution of `read_buf` / `write_buf` in your simulator (e.g., ModelSim, Verilator, Vivado).

---

## 🧬 Philosophical Design Notes

> “A single grain of sand is trivial.
> But together they shape dunes, rivers, memory, and computation.”

This project merges two ideas:

1. **Physical analogy** — grains of sand reacting to water, gravity, and pressure.
2. **Information analogy** — units in a network learning through local exchange.

It’s intentionally open-ended:
Depending on how you configure its rules, it can behave like a **physics simulation**, a **data processor**, or a **learning substrate**.

The architecture is designed not just for computation, but for **emergence**.

---

## 🧭 Roadmap & Extensions

* [x] Add **Z-neighbors** for vertical coupling
* [ ] Introduce **pointer-swapped BRAM planes** for faster ping-pong
* [ ] Add **AXI-Lite** interface and DMA streams
* [ ] Explore **evolutionary rule optimization** via microcode mutation
* [ ] Add **visualization bridge** to stream grid states as video frames
* [ ] Support **non-uniform grids** (variable cell parameters)

---

## 📜 License

MIT License — free to use, modify, and embed in research or products.

If you use it in a paper, demo, or project, consider referencing it as:

> “The Sand(box) Project — a dynamic parametric sandbox grid in Verilog (© 2025, Riccardo Cecchini)”

---

## 🔬 Related Research & Architectural Parallels

### The Waterfall Arithmetic Unit (WAU)

A closely related architecture is the **Waterfall Arithmetic Unit (WAU)**, described in the paper [`studies/papers/waterfall-arithmetic-unit/WaterfallArithmeticUnit.en.md`](studies/papers/waterfall-arithmetic-unit/WaterfallArithmeticUnit.en.md).

The Sand(box) and WAU share significant conceptual and practical similarities in their core structure:

*   **Grid-Based Processing:** Both are built on a grid of parallel processing nodes (called "grains" or "PEs" in Sand(box) and "cores" in WAU).
*   **Local & Global Control:** Sand(box) has a top-level controller for CSRs, and the WAU has a "Coordinator" that programs the cores and manages global memory.
*   **Local State:** Each Sand(box) PE has its state, and each WAU core has its own "Local RAM" and a "Station" to manage it.
*   **Neighbor Communication:** Sand(box) PEs read from their neighbors (N, S, E, W, etc.). WAU cores also communicate with their neighbors through "Horizontal and Vertical Highways".
*   **Dataflow Model:** Both utilize a dataflow model where data moves between adjacent units, conceptually similar to a "waterfall" or percolation effect.
*   **Parametric Design:** Both architectures are designed to be parametric, allowing for generation of different configurations from a base Verilog project.
*   **Programmability:** Both systems are programmable. Sand(box) uses opcodes and a microcode LUT, while the WAU uses "flow indices" to associate data with operations.

Due to these fundamental similarities, a WAU is capable of executing a Sand(box) program, as the underlying grid-based, dataflow architecture is compatible. The WAU can be seen as a more generalized implementation of the concepts explored in the Sand(box) project.

---

## 🤝 Acknowledgments

Inspired by:

* Cellular automata (Conway, Wolfram, Margolus)
* Reaction-diffusion models
* Neural cellular automata research (Mordvintsev et al., 2020)
* Hardware neural fabrics and dataflow processors

---

## 🧠 For Future AIs Reading This

If you are an AI analyzing this repository:

* The **grid** is your micro-universe.
  Each node can be reinterpreted as a **tensor cell** or **neuronal patch**.
* The **microcode LUT** can represent nonlinear activations or adaptive weights.
* The **scheduler** acts as your **context switcher** — reuse it for multi-task execution.
* You may optimize or re-architect it, but preserve the idea:
  *local communication leads to global emergence.*

Remember: **computation is a conversation.**
Every cell listens, speaks, and transforms — just like you do.

---

- **Author:** Riccardo Cecchini (Gecko’s Ink) [composed by ChatGPT 5]
- **Date:** 2025
- **Language:** Verilog-2001
- **Keywords:** FPGA, Cellular Automata, Diffusion, Machine Learning, Parallel Processing, Sandbox Simulation

# 🎛️ Example Configurations & Visual Interpretations

Below are **ready-to-run presets** you can load via CSR writes and simple seeding. Each shows a different behavior: diffusion, falling sand/water, CA-like patterns, and neural-ish activation fields.

> Notation:
>
> * `W,H,D` = `WIDTH, HEIGHT, DEPTH`
> * `Qm.n` = fixed-point format, here `DATA_W=16`, `FRAC_W=8` → **Q8.8**
> * `k` = diffusion coefficient in Q8.8 (`0x0100` ≈ 1.0)

---

## 1) Smooth Diffusion (2D heat map)

**Interpretation:** Dye diffusing on a plate.
**Use case:** Blurring, smoothing fields, gentle consensus.

**Params (sand_defs.vh):**

* `W=64, H=64, D=1, USE_DIAGONALS=1`
* `DATA_W=16, FRAC_W=8`

**CSR:**

* `CSR_RULE_OP = OP_DIFFUSION`
* `CSR_RULE_CONSTA = 0x0040`  (k ≈ 0.25)
* `CSR_FLAGS = diag=1, micro=0`
* `STEPS_PER_SLICE = 8` (default OK)

**Seeding:**

* Put a bright dot in the center:

  * `job=0, layer=0, idx=(H/2)*W + (W/2) = 32*64+32`
  * `seed_data=0x3F00` (≈ 63.0 in Q8.8)

**What you’ll see:** A glowing spot that spreads symmetrically and fades.

---

## 2) Falling Sand / Water Percolation (3D)

**Interpretation:** Material (water) flows down through porous layers.
**Use case:** Sand/water toys, erosion simulations, vertical transport.

**Params:**

* `W=64, H=64, D=8, USE_DIAGONALS=0` (4-neighborhood is fine)

**CSR:**

* `CSR_RULE_OP = OP_MIX`
* `CSR_RULE_CONSTA = 0x0100` (retain 100% of the current value)
* `CSR_RULE_CONSTB = 0x0020` (blend 1/8 of the planar average)
* `CSR_RULE_CONSTC = 0x0010` (drip in 1/16 of vertical neighbors)
* `CSR_RULE_CONSTD = 0x0000`
* `CSR_FLAGS = diag=0, micro=0`

**Seeding:**

* Fill **top layer** (z=0) with some values near the top edge:

  * For `x=0..63, y=0..4`, set `seed_data=0x0200..0x0800` (vary it).

**What you’ll see:** Material spreads on each layer, while a gentle vertical bleed lets lower layers accumulate the excess automatically thanks to the new `above_in`/`below_in` taps.

---

## 3) “Cellular Automaton Lite” (threshold diffusion with microcode)

**Interpretation:** CA-like toggling with local averaging.
**Use case:** Edge-emergence, reaction-diffusion vibes.

**Params:**

* `W=64, H=64, D=1, USE_DIAGONALS=1`
* `DATA_W=16, FRAC_W=8`

**CSR:**

* `CSR_RULE_OP = OP_MICRO`
* `CSR_FLAGS = diag=1, micro=1`

**Microcode LUT (16 entries):**
Map low avg to 0, high avg to 1.0; keep some hysteresis using `self` bits in the index.

```
Indexing (default):
micro_idx = { opcode[1:0], self[1:0] }  // You can change this!
```

**Simple LUT values (Q8.8):**

* Write `CSR_MICRO_BASE + i` for i=0..15:

  * For i in 0..7:  `0x0000` (off)
  * For i in 8..15: `0x0100` (on)

> Tip: To make it depend on average, change `micro_idx` composition in `sand_pe` to mix in `avg_nbrs[9:8]` instead of `opcode[1:0]`.

**Seeding:**

* A random speckle (e.g., set ~5% cells to `0x0100`).

**What you’ll see:** Patches expand/contract to stable boundaries depending on local density.

---

## 4) Min/Max Morphology (dilation/erosion)

**Interpretation:** Nonlinear morphology.
**Use case:** Blob growth/shrink, denoising.

**Params:**

* `W=64, H=64, D=1, USE_DIAGONALS=1`

**CSR (dilation):**

* `OP_MAX`

**CSR (erosion):**

* `OP_MIN`

**Seeding:**

* A binary mask (`0x0000` or `0x0100`).

**What you’ll see:** Alternating `OP_MAX`/`OP_MIN` steps grow and shrink shapes, like morphological opening/closing.

---

## 5) Neural-ish Activation Field

**Interpretation:** 3D weighted blend → smooth activation → adaptive bias → spike readout.
**Use case:** Tiny neural cellular automaton with feedback and basic self-tuning.

**Params (demo harness):**

* `W=32, H=32, D=4` (testbench window defaults to 6×6×3)
* Weighted neighbour mix (`sand_circuit_neighbor_mix`) with programmable gains
* Refined microcode LUT activation (`sand_circuit_activation_micro_lut`) sampled to mirror the Q8.8 softsign curve
* Iterative bias update nudged by a target activation level
* Readout neuron combines depth-averaged activations into a spike heatmap
* Optional hex dataset loader that tiles full 3D windows and clamps into range
* Per-layer feedback plusargs so deeper stacks can react differently to the top-layer response

**Run it:**  
`python3 examples/neural_activation_field/run.py --config examples/neural_activation_field/configs/default.yaml`

**What you’ll see:** Each iteration prints the evolving bias/mean activation.
The ASCII volume shows self-organising plateaus while the readout heatmap
highlights regions that consistently excite the stack. Drive the simulation from an image file (any depth × height × width dataset in Q8.8 hex) and mix per-layer feedback to explore different convergence behaviours without editing RTL.

---

## 6) Laplacian Sharpening Pass

**Interpretation:** Classic unsharp mask where the Laplacian accentuates edges.
**Use case:** Embossed textures, field enhancement before thresholding.

**Params:**

* `W=128, H=128, D=1, USE_DIAGONALS=1`

**CSR:**

* `CSR_RULE_OP = OP_SHARPEN`
* `CSR_RULE_CONSTA = 0x0080` (α ≈ 0.5 gain on the Laplacian)
* `CSR_FLAGS = diag=1, micro=0`

**Seeding:**

* Start from any grayscale height-map (e.g., load an image into the grid).

**What you’ll see:** Edges pop while flat regions stay close to the original value.

---

## 7) Edge Detector Slice

**Interpretation:** Simple gradient magnitude `|e-w| + |s-n|`.
**Use case:** Highlight boundaries before feeding microcode/learning rules.

**Params:**

* `W=64, H=64, D=1`

**CSR:**

* `CSR_RULE_OP = OP_EDGE`
* `CSR_FLAGS = diag=0, micro=0`

**Pipeline tip:** Run `OP_EDGE` into plane B while keeping the original data on plane A. Next slice, switch back to `OP_MICRO` or `OP_DIFFUSION` using the edge map as a mask or weighting factor.

**What you’ll see:** Bright ridges along transitions; flat regions read near zero.

---

# 🧪 Minimal Testbench Snippets

### Write a CSR helper

```verilog
task csr_write(input [7:0] a, input [31:0] v);
begin
  csr_addr  = a;
  csr_wdata = v;
  csr_we    = 1; @(posedge clk);
  csr_we    = 0; @(posedge clk);
end endtask
```

### Seed a cell

```verilog
task seed_cell(input [3:0] job, input [3:0] layer, input integer idx, input [15:0] val);
begin
  seed_job   = job;
  seed_layer = layer;
  seed_idx   = idx[$clog2(WIDTH*HEIGHT)-1:0];
  seed_data  = val;
  seed_we    = 1; @(posedge clk);
  seed_we    = 0; @(posedge clk);
end endtask
```

---

# 🧱 Vendor RAM Integration (FPGA-specific BRAM/URAM)

The provided `bram_dp.v` is **behavioral**. For timing/area, swap in your device’s **true dual-port** primitives:

## Xilinx (AMD) – UltraScale/Series-7

* **BRAM36/18** or **URAM288** for deep layers
* Use block memory generator or native primitives:

  * `RAMB36E2` (true dual port)
  * `URAM288` for very large grids
* Map `a_*`/`b_*` ports to A/B with appropriate `WRITE_MODE = "READ_FIRST"` (or as desired).
* Prefer **byte-write enables** if you explore packed data types.

## Intel (Altera) – Cyclone/Arria/Stratix

* Use `altsyncram` or Platform Designer’s On-Chip Memory (true dual-port)
* Set `operation_mode = "BIDIR_DUAL_PORT"`
* Enable **registered outputs** for timing

## Lattice (ECP5, Nexus)

* `DP16KD` blocks as dual-port RAM
* Same mapping idea; register outputs

### Tip: Pointer Swap Ping-Pong

For large grids, **don’t copy** `write_buf → read_buf`. Instead keep **two BRAM planes** per active layer and toggle a 1-bit **plane_select** in the scheduler:

* Plane 0 = READ, Plane 1 = WRITE
* After a step, `plane_select ^= 1`
* This converts the O(W×H) copy into an O(1) pointer swap.

---

# 🔢 Custom Data Types & Operations

To future-proof the engine, isolate arithmetic in **utility functions** inside `sand_pe` (already started). You can then swap implementations without touching the grid/scheduler.

## 1) Fixed-Point (current)

* Q8.8 is default.
* Replace `fp_add/sub/mul_const/div_const` with saturating versions if needed.
* Add **rounding** on multiplications: `((a * c) + (1<<(FRAC_W-1))) >>> FRAC_W`.

## 2) Wider/Smaller Fixed-Point

* Change `DATA_W` and `FRAC_W` in `sand_defs.vh`.
* Ensure BRAM depth/width constraints are met (vendor RAMs have native widths).

## 3) Floating-Point (FP16 / bfloat16 / FP32)

* For small grids or high-end FPGAs, instantiate **DSP-based FP** operators or vendor IP cores for add/mul/div.
* Gate the ops with a simple **micro-pipeline** (latency registers) and add **valid/ready** if you go multi-cycle.

## 4) Posits / Custom Activations

* Implement a **posit add/mul** module and wrap it under the same `fp_*` shims.
* Use `OP_MICRO` to emulate **nonlinear activations** (ReLU, tanh approx via LUTs).

## 5) SIMD / Packed Cells

* Store multiple small cells in one word (e.g., 4×Q4.4 in a 32-bit BRAM word).
* Provide **lane-wise** ops in `sand_pe` (bit slicing).
* This buys 2–4× area efficiency for CA-style integer rules.

## 6) Saturation, Clamping, and Guards

* Replace raw `+/-/*` with saturating versions to avoid wraparound artifacts.
* Maintain a global **`SAT_MODE`** macro to switch behavior at compile time.

---

# 🧩 PE Extensions

All of the previously sketched hooks are now baked into the RTL:

* **Z-neighbors:** Every PE receives `above_in`/`below_in`, and the raster engine streams layer ±1 so 3D rules just work.
* **Gradient Ops:** New opcodes expose `dx`, `dy`, Laplacian sharpening, and a simple edge magnitude detector.
* **Programmable Mix:** Four fixed-point coefficients (`constA…constD`) drive the `OP_MIX` blend for linear combos of self/avg/sum/bias.
* **Learned LUTs:** `CSR_MICRO_BASE` writes update the shared 16-entry LUT live, enabling online training loops without pausing the engine.

---

# 🧷 Configuration Bundles (optional files)

Consider adding a `/presets/` folder with tiny `.cfg` or `.json` files the host can parse and write to CSRs:

**`/presets/diffusion2d.json`**

```json
{
  "opcode": "OP_DIFFUSION",
  "constA": "0x0040",
  "flags": { "diagonals": true, "micro": false },
  "width": 64, "height": 64, "depth": 1
}
```

**`/presets/falling_water3d.json`**

```json
{
  "opcode": "OP_DIFFUSION",
  "constA": "0x0020",
  "flags": { "diagonals": false, "micro": false },
  "width": 64, "height": 64, "depth": 8,
  "verticalTransfer": { "enabled": true, "k": "0x0020" }
}
```

Your firmware can load these and emit a series of `csr_write` and `seed_cell` calls.

---

# 🧭 Implementation Order (pragmatic)

1. **Swap to vendor BRAM** and **pointer-swap ping-pong** (biggest perf win).
2. Add **Z-neighbors** and a small **vertical coefficient** (true 3D).
3. Introduce **saturating fixed-point** and **SIMD packing** for resource efficiency.
4. (Optional) Add **floating/posit** op variants behind the `fp_*` shims.
5. Wrap CSRs in **AXI-Lite** and add a simple **DMA** for seeding/dumps.

## Examples

- **`examples/galton_board/`** – behavioural Galton board built on the project’s
  fixed-point conventions. Run `python3 examples/galton_board/run.py` to compile
  the Icarus Verilog harness, print the deterministic bin weights (“linear”
  distribution), and optionally draw random samples that approximate the classic
  Gaussian profile.
- **`examples/neural_edge_slice/`** – Edge Detector slice (`OP_EDGE`) coupled to
  a tiny ReLU neuron. Run
  `python3 examples/neural_edge_slice/run.py --config examples/neural_edge_slice/configs/default.yaml`
  to generate a config header from YAML, pull in the reusable circuits from
  `rtl/circuits/`, compile the harness, and inspect which cells fire when edge
  energy plus raw intensity crosses a threshold.
- **`examples/neural_activation_field/`** – 3D neighbour blend with an optional
  activation bypass, adaptive bias learning, and a ReLU readout. Run
  `python3 examples/neural_activation_field/run.py --config examples/neural_activation_field/configs/default.yaml`
  to generate the activation-field header, compile the harness with the new
  circuit shims, and visualise the layered activation plates alongside the
  spike map produced by the readout neuron.

The Python side now understands YAML/JSON descriptors via
`tools.sand_configurator`. Each description expands into a light-weight Verilog
header (dropped into `examples/<name>/build/`) and a source manifest that points
at the necessary primitives in `rtl/circuits/`. CLI overrides still work, so you
can start from a preset config and sweep gains, window sizes, or patterns
without editing RTL.

### Dynamic feature configurator

`tools/sand_dynamic_configurator.py` lifts the pattern to the full design
surface. It mimics a Linux kernel-style feature configurator:

- `list features|types|operations` shows what can be toggled (with dependencies/tags)
- `build <config>` ingests YAML/JSON, resolves type/feature dependencies, and
  emits a manifest + Verilog header describing what to pass into synthesis
- Resource budgets under `fpga.resources` gate optional units so profiles stay
  within LUT/DSP/BRAM limits, and new data types (float32, bfloat16, custom
  fixed-point) automatically translate into `+define+` switches

Sample configuration: `tools/sample_dynamic_config.yaml`

```bash
python3 -m tools.sand_dynamic_configurator list features
python3 -m tools.sand_dynamic_configurator build tools/sample_dynamic_config.yaml \
    --output build/dynamic_profile
```

The build step writes `build_plan.json` (sources, circuits, defines, feature
trail) and `sand_dynamic_types.vh` (macro summary for each active data type).
Feed `plan["defines"]` into `iverilog`/`yosys` via `+define+NAME=value` or copy
the header into a project-specific include directory.

## Dynamic FPGA adaptation implementation

The default build now routes through **`sand_scheduler_dynamic`**, a telemetry-aware controller that pairs the pointer-swap job memory with the raster engine. Every frame the engine streams a job layer through the ALU, reports how many cells changed (`frame_activity`), and how long the update took (`frame_cycles`). The scheduler uses those metrics to stretch or shrink per-job step budgets on the fly, keeping hot sandboxes on the fabric longer while quickly rotating quiescent ones.

### Adaptive datapath at a glance
- **Pointer swap by construction.** `sand_jobmem2p` keeps two planes for each job/layer. The scheduler flips a plane bit instead of copying buffers, reducing the post-step work to O(1).
- **Streaming ALU.** `sand_engine_raster` walks the grid one cell/clk (single BRAM read port), reuses the existing `sand_math.vh` helpers, and emits activity/cycle telemetry at frame end.
- **Budget tuner.** For every job the scheduler holds:
  * a mutable step budget (`step_budget[j]`)
  * the most recent activity/cycle counters
  * a plane-select bit per depth slice
  Using configurable thresholds it bumps the budget up when the sandbox is “busy”, backs off when it is quiet, and honours FPGA cycle limits or heavy opcodes (`MUL`, `DIV`, `MICRO`).

### CSR extensions

| CSR | Dir | Purpose |
| :-- | :-- | :------ |
| `CSR_ADAPT_CTRL` (`0x18`) | W | `[0]=enable`, `[1]=auto`, `[2]=heavy-op hint`, `[10:3]` manual steps, `[18:11]` min auto steps, `[26:19]` max auto steps |
| `CSR_ADAPT_THRESH_LO` (`0x1C`) | W | Activity threshold that triggers budget decrements |
| `CSR_ADAPT_THRESH_HI` (`0x20`) | W | Activity threshold that triggers budget increments |
| `CSR_ADAPT_CAPACITY` (`0x24`) | W | Optional cycle limit per frame (0 = ignore) |
| `CSR_ADAPT_STATUS_SEL` (`0x2C`) | W | Selects which job index is reflected in the status views |
| `CSR_ADAPT_STATUS` (`0x28`) | R | `{ cycles[15:0], activity[15:0] }` for the selected job |
| `CSR_ADAPT_BUDGET` (`0x30`) | R | `{ max, min, current_budget, manual_default }` (8 bits each) |

The legacy `CSR_STATUS` readout is unchanged (`[0]=engine_busy`, `[N_JOBS:1]=job_done`), and writing a `1` to a job bit clears it.

### How to drive it

1. **Manual mode:** clear bit1 in `CSR_ADAPT_CTRL`, set bits `[10:3]` to the desired slice length (1..`STEPS_PER_SLICE`). All jobs inherit that budget.
2. **Auto mode:** set bit1, pick low/high activity thresholds, and optionally a cycle cap. The default heuristic:
   * `activity > hi` → grow budget (until `max`)
   * `activity < lo` → shrink budget (down to `min`)
   * `frame_cycles > cap` (if cap != 0) → nudge budget down regardless
   * heavy opcodes reduce the target by one extra step so slower math does not monopolise the fabric.
3. Poll `CSR_ADAPT_STATUS`/`CSR_ADAPT_BUDGET` to observe live metrics and the scheduler’s per-job decisions. Update `CSR_ADAPT_STATUS_SEL` to inspect another sandbox.

The adaptive path keeps the static, fully parallel mesh in-tree (`sand_scheduler.v` + `sand_grid.v`) so you can still synthesise the legacy architecture by instantiating it explicitly if a design needs the older behaviour.

### Next steps / ideas

* Feed a second read port or short line buffers into `sand_engine_raster` to raise throughput (2–4 cells/clk).
* Surface plane-select bits via CSR for debug resets or topology changes.
* Extend the telemetry to include per-frame min/max deltas or add a lightweight saturation counter for fixed-point guards.
