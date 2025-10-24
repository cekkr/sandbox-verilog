!!! CRITICAL PROTOCOL !!!
- AI agent MUST refresh AI_REFERENCE.md after every code mutation before yielding control.

PROJECT_VECTOR:
- Repo: sandbox-verilog — parametric Verilog sandbox engine (cellular automaton / streaming PE fabric).
- License: MIT (LICENSE).
- Languages: Verilog RTL core, Python tooling, Markdown docs.
- Sim deps: iverilog, vvp, Python ≥3.8.

DIRECTORY_MAP:
- rtl/: synthesizable path (`sand_defs.vh`, `sand_math.vh`, `sand_pe.v`, `sand_engine_raster.v`, `sand_jobmem2p.v`, `sand_scheduler_dynamic.v`, `sand_top.v`, `bram_tdp_wrap.v`).
- rtl/legacy/: legacy fully parallel architecture (`sand_grid.v`, `sand_scheduler.v`, `sand_jobmem.v`).
- tools/: Python utilities (`sand_runner.py`, `__init__.py`).
- examples/: behavioural demos (`galton_board`, `neural_edge_slice`) with Verilog testbenches + Python runners.
- README.md: human-friendly deep dive (mirror but more verbose).
- .gitignore: Python/build artefact ignores (standard template).

RTL_FLOW:
1. Host drives `sand_top` CSR + seed interfaces.
2. `sand_scheduler_dynamic` captures CSR writes, seeds job memory, manages adaptive budgets, microcode, enhanced unit configs, per-job windows.
3. Scheduler creates frame requests for `sand_engine_raster` (job/layer selection, plane select).
4. `sand_engine_raster` streams grid cells, evaluates ALU (`sand_pe` logic inline), writes updates into opposite plane.
5. `sand_jobmem2p` pointer-swap BRAM (via `bram_tdp_wrap`) feeds read plane and accepts write plane.
6. Engine telemetry (`frame_activity`, `frame_cycles`) feeds scheduler, which updates job_done + budgets.

CONFIG_CORE (`rtl/sand_defs.vh`):
- Grid params: `DATA_W`, `FRAC_W` (default Q8.8), `WIDTH`, `HEIGHT`, `DEPTH`, `N_JOBS`, `STEPS_PER_SLICE`, `USE_DIAGONALS`.
- CSR map: opcode + const registers, microcode region, adaptive control (`CSR_ADAPT_*`), enhanced flux/pressure/backprop controls (`CSR_UNIT_*`), window sizing/offset/status CSRs.
- Defaults: `ADAPT_DEFAULT_*` macros, opcode definitions (`OP_NOP`..`OP_MIX`).

MATH_HELPERS (`rtl/sand_math.vh`):
- Macros for saturating add/sub (`FP_ADD`, `FP_SUB`), fixed-point multiply/divide with optional rounding (`FP_MUL_Q`, `FP_DIV_Q`).
- Tunables: `SATURATE`, `ROUND_MUL`.

PROCESSING_ELEMENT (`rtl/sand_pe.v`):
- Inputs: cell + 8 planar neighbors + above/below + config/microcode.
- Opcodes cover diffusion, clamp, min/max, Laplacian, sharpen, edge magnitude, water flux, pressure/backprop loops, micro LUT.
- Microcode index default `{opcode[1:0], self[1:0]}`; expects 16-entry DATA_W LUT.
- Uses local helper functions for fixed-point math; supports diagonal toggle, vertical neighbors for 3D.

STREAM_ENGINE (`rtl/sand_engine_raster.v`):
- FSM drives single-port raster: READ neighbors -> ALU -> WRITE -> advance coordinates; extra state for iterative pressure.
- Maintains per-frame activity/cycle counters.
- Samples config on `start_frame`; mirrors scheduler-provided unit weights, reversing flags, pressure iterations, window bounds.
- Accepts micro_lut writes (shadow storage) when CSR triggers.
- Supports unit windowing via width/height/offset registers; clamps indices via helper functions.

MEMORY PLANE (`rtl/sand_jobmem2p.v`, `rtl/bram_tdp_wrap.v`):
- Addressing: {job, layer, plane, cell}.
- Seed port writes explicit plane (0/1); engine writes opposite plane when `eng_write_other_plane` asserted.
- `bram_tdp_wrap` behavioural true dual-port RAM; vendor-specific ifdefs stubbed (Xilinx/Intel/Lattice).

SCHEDULER (`rtl/sand_scheduler_dynamic.v`):
- CSR decoder for opcode, consts, micro LUT (write strobe/addr/data), enhanced unit control registers, adaptive knobs, per-job window tables.
- Adaptive budget logic: manual vs auto mode, thresholds, cycle limit, heavy-op hint; per-job `step_budget`, `last_activity`, `last_cycles`.
- Manages plane select bits per job/layer; flips on frame completion; updates `job_done`.
- Interfaces: instantiates `sand_jobmem2p` (seed + engine) and `sand_engine_raster`; muxes window registers per job.
- Exposes telemetry via `CSR_ADAPT_STATUS`, `CSR_ADAPT_BUDGET`, selects job with `CSR_ADAPT_STATUS_SEL`.

TOP WRAPPER (`rtl/sand_top.v`):
- Connects external CSR/seed buses to scheduler; outputs `job_done`.
- Parameterization inherited from `sand_defs.vh`.

LEGACY PIPELINE (`rtl/legacy/*`):
- `sand_grid.v`: mesh-based PE array (non-streaming).
- `sand_scheduler.v`: legacy scheduler matching parallel grid.
- `sand_jobmem.v`: legacy job memory (pre pointer-swap). Retained for reference/comparison.

PYTHON TOOLING (`tools/sand_runner.py`, `tools/__init__.py`):
- `SandToolError`: exception for tool failures.
- `IcarusBuildConfig`: dataclass describing compile inputs.
- `compile_icarus`: runs `iverilog -g2012` with include dirs/defines/top; returns VVP path.
- `run_vvp`: executes compiled simulation, returns stdout, raises on non-zero exit.
- `q_to_float`: converts fixed-point to float.
- `__init__.py`: re-exports helpers for convenience.

EXAMPLE DEMOS (`examples/`):
- `galton_board`: `galton_board_tb.v` behavioural Galton board using Q8.8 arrays; `run.py` compiles via sand_runner, applies plusargs (`LEFT_PCT`, `RIGHT_PCT`, board dims), parses `GALTON.bin` output, optional random sampling, JSON export.
- `neural_edge_slice`: `neural_edge_slice_tb.v` computes edge magnitude + ReLU gating; `run.py` compiles, parses stdout via regex to grids, renders ASCII heatmaps (`edge`, `relu`, binary fire), optional JSON dump; CLI exposes pattern/gain/bias/threshold/window options.

WORKFLOW SNAPSHOT:
- Edit global macros in `rtl/sand_defs.vh` to match target FPGA/sim.
- Seed job planes via CSR or seed port (plane 0 default); pointer swap flips per frame.
- Program opcodes, constants, microcode, unit weights via CSR writes.
- Monitor `job_done`, `CSR_ADAPT_STATUS`, `CSR_ADAPT_BUDGET` to track activity and scheduler decisions.
- Use example scripts for regression demos (`python3 examples/.../run.py`); requires iverilog/vvp in PATH.

HOUSEKEEPING NOTES:
- README.md: extended architecture narrative and usage guidance.
- LICENSE: MIT 2025 Riccardo Cecchini.
- No dedicated test suite beyond examples; consider extending examples/tests when modifying RTL.

REMINDER_LOOP:
- After any AI-driven repository modification: re-evaluate affected modules, update AI_REFERENCE.md accordingly, confirm reminder stays prominent.
