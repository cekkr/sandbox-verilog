# 🏖️ The Sand(box) Project

### *A Dynamic, Concurrent, Multi-Dimensional Sandbox Engine in Verilog*

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
* Evolves **in parallel** with all others, forming emergent patterns or stable flows

When seen in 3D, each **layer** of sand passes information to the next, like **water percolating** or **neurons activating in depth**.
The entire structure behaves a bit like a **machine-learning model** — one that learns by local interactions rather than global training.

---

## ⚙️ Architecture

The project is organized into clean, layered modules:

| Module                      | Description                                                                                                                                                                |
| :-------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`src/sand_defs.vh`**          | Global parameter file — defines word widths, grid size, number of jobs, math opcodes, and CSR addresses. Edit this first to customize your FPGA target.                    |
| **`src/sand_math.vh`**          | Saturating/rounding fixed-point helpers used by the PE and raster engine.                                                                                                  |
| **`src/sand_pe.v`**             | The *Processing Element* (one grain). Reads its 4–8 neighbors and applies an operation (sum, diffusion, clamp, etc.) or a user-defined microcode rule.                    |
| **`src/sand_scheduler_dynamic.v`** | Adaptive round-robin scheduler. Tracks per-job activity, selects step budgets, and drives the pointer-swap raster engine (`sand_engine_raster`).                         |
| **`src/sand_engine_raster.v`** | Streaming single-port engine that walks the grid cell-by-cell, produces activity metrics, and writes results into the opposite memory plane.                          |
| **`src/sand_jobmem2p.v`**     | Two-plane dual-port job memory. Each job/layer owns {read,write} planes and a plane-select bit toggled by the scheduler.                                              |
| **`src/sand_top.v`**            | Integration wrapper exposing the CSR bus, seeding port, and the adaptive core.                                                                                            |
| **`src/bram_tdp_wrap.v`**   | Portable true dual-port BRAM wrapper (vendor-inferable).                                                                                                                   |
| **`src/legacy`** / (**`sand_grid.v` / `sand_scheduler.v` / `sand_jobmem.v`**) | Legacy fully-parallel path kept for reference (instantiates an in-core `WIDTH × HEIGHT` PE mesh).                                             |

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

### Unit Dynamics & Windows

The enhanced **unit** pipeline lets you bias each layer like a Galton board: you can stream weighted flux from the top, relax pressure iteratively, or fold in a backprop-style correction while the raster engine walks the grid.

Key CSRs that drive this behaviour:

| CSR | Description |
| :-- | :---------- |
| `CSR_UNIT_CTRL` | Bit0 enables flux, bits1-2 route overflow (up/down), bit3 optionally forces diagonal sampling for pressure, bits15:8 set the pressure iteration budget (1‥32) |
| `CSR_UNIT_WINDOW_WH` / `CSR_UNIT_WINDOW_OFFSET` | Per-job active window (width/height and X/Y offset). Select the target job with `CSR_JOB_SELECT` before writing. |
| `CSR_UNIT_STATUS_WINDOW` / `CSR_UNIT_STATUS_OFFSET` | Read back the sanitized window settings for the selected job. |
| `CSR_UNIT_FLUX_*` | Directional weights (`TOP`, `BOTTOM`, `SIDE`, `RETAIN`, `PREV`), a saturation threshold, and fractional coefficients for overflow feedback. |
| `CSR_UNIT_PRESSURE_GAIN` | Fixed-point exchange rate multiplied during each pressure iteration. |
| `CSR_UNIT_BACKPROP_*` | Learning-rate, neighbour gain, and decay factors for the gradient update primitive. |

**How the new opcodes map to the knobs**

- `OP_WATER_FLUX` consumes the directional weights and threshold, mixes in `constB` as the vertical/backfeed term, and bleeds overflow according to the up/down coefficients.
- `OP_PRESSURE` executes as many micro-iterations as requested, multiplying the difference between the running pressure and the neighbour average by `CSR_UNIT_PRESSURE_GAIN`.
- `OP_BACKPROP` treats `constB` as the target signal, `CSR_UNIT_BACKPROP_LR` as the learning rate, and nudges the cell using the neighbour coupling (`NEIGH`) and decay values.

Use window offsets to shrink the active region when a model only occupies part of the fabric: the raster engine will skip untouched cells, saving cycles and bandwidth without requiring you to resize the underlying BRAM planes.

---

## 🧩 The Processing Element (`sand_pe`)

Each PE runs the core update rule:

```
next = f(self, neighbors, constA, constB, opcode)
```

### Supported Operations

| Opcode            | Behavior                                        |
| :---------------- | :---------------------------------------------- |
| `OP_SUM_NBRS`     | Sum of neighbors                                |
| `OP_AVG_NBRS`     | Average of neighbors                            |
| `OP_ADD_CONST`    | Add constant A                                  |
| `OP_SUB_CONST`    | Subtract constant A                             |
| `OP_MUL_CONST`    | Multiply by constant A                          |
| `OP_DIV_CONST`    | Divide by constant A                            |
| `OP_DIFFUSION`    | `self + k*(avg - self)` (soft diffusion)        |
| `OP_MIN / OP_MAX` | Minimum or maximum with neighbors               |
| `OP_CLAMP`        | Clamp between constA..constB                    |
| `OP_WATER_FLUX`   | Weighted water flux blending + overflow bleed   |
| `OP_PRESSURE`     | Iterative pressure/exchange relaxation          |
| `OP_BACKPROP`     | Single-step gradient update toward target       |
| `OP_MICRO`        | Look up a user-defined rule from a 16-entry LUT |

### Microcode LUT

You can define a 16-entry lookup table (`micro_lut`) via CSR writes.
It lets you encode small nonlinear or symbolic rules (e.g., thresholds, Boolean masks, learned coefficients).
Index computation is customizable in the code (`micro_idx` logic).

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
To extend the PE for true 3D neighbor access, simply add `above_in` and `below_in` wires and modify the `sand_grid` generator accordingly — the rest of the system already handles layers.

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

* [ ] Add **Z-neighbors** for vertical coupling
* [ ] Introduce **pointer-swapped BRAM planes** for faster ping-pong
* [ ] Add **AXI-Lite** interface and DMA streams
* [ ] Explore **evolutionary rule optimization** via microcode mutation
* [ ] Add **visualization bridge** to stream grid states as video frames
* [ ] Support **non-uniform grids** (variable cell parameters)

---

## 📜 License

MIT License — free to use, modify, and embed in research or products.

If you use it in a paper, demo, or project, consider referencing it as:

> “The Sand Project — a dynamic parametric sandbox grid in Verilog (© 2025, Gecko’s Ink / Riccardo Cecchini)”

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

**Author:** Riccardo Cecchini (Gecko’s Ink) [no, seriously, written by ChatGPT 5]
**Date:** 2025
**Language:** Verilog-2001
**Keywords:** FPGA, Cellular Automata, Diffusion, Machine Learning, Parallel Processing, Sandbox Simulation

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
* Consider extending later with Z-neighbors (see roadmap).

**CSR:**

* `CSR_RULE_OP = OP_DIFFUSION` (horizontal smoothing)
* `CSR_RULE_CONSTA = 0x0020` (k ≈ 0.125)
* `CSR_FLAGS = diag=0, micro=0`

**Seeding:**

* Fill **top layer** (z=0) with some values near the top edge:

  * For `x=0..63, y=0..4`, set `seed_data=0x0200..0x0800` (vary it).

**Scheduler hint:**

* Run normally; the provided PE is 2D. To emulate percolation, after each `S_STORE` of layer `z`, add a small **vertical transfer** when loading `z+1` (e.g., copy a fraction of `z`’s stored values into `z+1` before running it). You can do this in the scheduler (temporary hack) or properly by **adding `above_in/below_in`** to `sand_pe` for real Z-coupling.

**What you’ll see:** Material spreads on each layer and appears to “move down” as lower layers pick up a fraction of upper layer values over time.

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

**Interpretation:** Weighted sum → nonlinearity (microcode) → stable field.
**Use case:** Tiny neural cellular automata prototype.

**Params:**

* `W=64, H=64, D=1, USE_DIAGONALS=1`
* `OPCODE = OP_MICRO`, `micro=1`

**Trick:** Use `OP_ADD_CONST` first to bias, then `OP_MICRO` next slice. Or fold bias into LUT.

**Microcode idea:**

* Use a soft-threshold LUT that maps `avg_nbrs - self` sign to {0, small, big}.
* Modify `micro_idx` to include `(avg_nbrs > self)` and a couple top bits from `avg_nbrs`.

**Seeding:**

* Low-amplitude noise.

**What you’ll see:** Regions settle into plateaus with crisp boundaries—like a low-res segmentation map.

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

# 🧩 Extending the PE (suggested hooks)

* **Z-neighbors:** Add `above_in`/`below_in` to `sand_pe` and feed from `layer-1 / layer+1`.
* **Gradient Ops:** Provide `dx = e - w`, `dy = s - n`, then support `OP_LAPLACIAN`, `OP_SHARPEN`, `OP_EDGE`.
* **Programmable Mix:** Add small coeff registers:
  `next = a*self + b*avg + c*sum + d` (all fixed-point).
* **Learned LUTs:** For ML-ish behavior, let a host rewrite `micro_lut` online as part of a training loop.

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
