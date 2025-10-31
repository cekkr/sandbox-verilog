!!! CRITICAL PROTOCOL !!!
- AI agent MUST refresh AI_REFERENCE.md after every code mutation before yielding control.
- AI agent MUST referesh README.md after a new implementation.

PROJECT_VECTOR:
- Repo: sandbox-verilog — parametric Verilog sandbox engine (cellular automaton / streaming PE fabric).
- License: MIT (LICENSE).
- Languages: Verilog RTL core, Python tooling, Markdown docs.
- Sim deps: iverilog, vvp, Python ≥3.8.

DIRECTORY_MAP:
- rtl/: synthesizable path (`sand_defs.vh`, `sand_math.vh`, `sand_pe.v`, `sand_engine_raster.v`, `sand_jobmem2p.v`, `sand_scheduler_dynamic.v`, `sand_top.v`, `bram_tdp_wrap.v`).
- rtl/circuits/: reusable combinational helpers (edge detector, neuron ReLU, neighbour mix, softsign activation, micro-lut activation).
- rtl/legacy/: legacy fully parallel architecture (`sand_grid.v`, `sand_scheduler.v`, `sand_jobmem.v`).
- rtl.yaml/: YAML mirror of synthesizable RTL (`tools/verilog_yaml_bridge.py` output; core modules expose ASTs, streaming blocks currently fall back to body text + metadata until the parser supports their SV features).
- tools/: Python utilities (`sand_runner.py`, `sand_configurator.py`, `sand_dynamic_configurator.py`, `sample_dynamic_config.yaml`, `__init__.py`).
- examples/: behavioural demos (`galton_board`, `neural_edge_slice`, `neural_activation_field`) with Verilog testbenches + Python runners.
- examples/neural_edge_slice/configs/: YAML presets that drive auto-generated config headers.
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
- Unit weight tuple: `capability` (saturation threshold), `channel` (directional weights), `friction` (reverse flow fractions + pressure gain) together describe per-edge flow limits; `CSR_UNIT_CTRL[2:1]` decides whether the vertical reverse fractions act as friction. Legacy `sand_pe` honours the same tuple whenever `unit_flux_enable` is asserted so the fully parallel grid mirrors the streaming engine; clearing the bit keeps the classic const-driven behaviour intact.
- Defaults: `ADAPT_DEFAULT_*` macros, opcode definitions (`OP_NOP`..`OP_MIX`).

MATH_HELPERS (`rtl/sand_math.vh`):
- Macros for saturating add/sub (`FP_ADD`, `FP_SUB`), fixed-point multiply/divide with optional rounding (`FP_MUL_Q`, `FP_DIV_Q`).
- Tunables: `SATURATE`, `ROUND_MUL`.

PROCESSING_ELEMENT (`rtl/sand_pe.v`):
- Inputs: cell + 8 planar neighbors + above/below + config/microcode.
- Opcodes cover diffusion, clamp, min/max, Laplacian, sharpen, edge magnitude, water flux, pressure/backprop loops, micro LUT.
- Microcode index default `{opcode[1:0], self[1:0]}`; expects 16-entry DATA_W LUT.
- Uses local helper functions for fixed-point math; supports diagonal toggle, vertical neighbors for 3D.
- Flux/pressure paths evaluate the tuple `{capability, channel, friction}` for both cells on an edge before committing the transfer; planar flows reuse `CSR_UNIT_PRESSURE_GAIN` as their friction scalar while the vertical bits gate the reverse coefficients. When `unit_flux_enable` is low the PE reverts to the legacy constA/constB/constC/constD implementation so older sandboxes keep working.

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

PYTHON TOOLING (`tools/sand_runner.py`, `tools/sand_configurator.py`, `tools/sand_dynamic_configurator.py`, `tools/verilog_yaml_bridge.py`, `tools/__init__.py`):
- `SandToolError`: exception for tool failures.
- `IcarusBuildConfig`: dataclass describing compile inputs.
- `compile_icarus`: runs `iverilog -g2012` with include dirs/defines/top; returns VVP path.
- `run_vvp`: executes compiled simulation, returns stdout, raises on non-zero exit.
- `q_to_float`: converts fixed-point to float.
- `sand_configurator`: parses YAML/JSON presets, resolves neural-edge and neural-activation parameter sets (including the new `activation.bypass` knob), writes example-specific headers (including fallback `NAF_FEEDBACK_PCT` for legacy plusargs), and enumerates required `rtl/circuits/` sources for any circuit list.
- `sand_dynamic_configurator`: kernel-style feature configurator that consumes high-level YAML/JSON, resolves feature/type/operation dependencies, checks resource budgets, emits `build_plan.json` (sources/defines/notes) plus `sand_dynamic_types.vh` summarising active data types/macros. CLI supports `list` (features/types/operations) and `build` (config → artefacts).
- `sample_dynamic_config.yaml`: example profile enabling ML-centric features, multiple type families (float32 default, extra fixed/float options), and two composite units; use it as a template with `python3 -m tools.sand_dynamic_configurator build tools/sample_dynamic_config.yaml --output build/dynamic_profile`.
- `verilog_yaml_bridge`: exports RTL into structured YAML (`export`) and regenerates RTL (`restore`). PyVerilog drives the AST path; the streaming RTL blocks still emit `kind: verilog_module_fallback` records (original text + interface summary) until the bridge grows full SystemVerilog coverage.
- `__init__.py`: re-exports helpers (runner + configurator) for convenience.

EXAMPLE DEMOS (`examples/`):
- `galton_board`: `galton_board_tb.v` behavioural Galton board using Q8.8 arrays; `run.py` compiles via sand_runner, applies plusargs (`LEFT_PCT`, `RIGHT_PCT`, board dims), parses `GALTON.bin` output, optional random sampling, JSON export.
- `neural_edge_slice`: `neural_edge_slice_tb.v` now instantiates primitives from `rtl/circuits/` (edge detector + neuron). `run.py` consumes optional YAML/JSON configs (`configs/default.yaml`) through `sand_configurator`, emits a generated header, includes the required library sources, still parses stdout to grids/heatmaps, and honours CLI overrides for pattern/gains/bias/threshold/window.
- `neural_activation_field`: `neural_activation_field_tb.v` blends 3D neighbours, optionally bypasses the activation LUT, adapts a bias toward a target, and feeds a ReLU readout neuron. `run.py` mirrors the other examples—reads YAML (`configs/default.yaml`), emits a header, compiles the harness with the neighbour-mix/micro-lut circuits, parses per-iteration telemetry plus the final volume/readout maps, and renders ASCII slices or dumps JSON. The LUT is still populated from softsign samples for symmetry, but you can disable it via `activation.bypass` in YAML or the CLI switches `--activation-bypass` / `--activation-micro`; the harness also accepts hex datasets (with padding/clamping) plus per-layer feedback gains.

WORKFLOW SNAPSHOT:
- Edit global macros in `rtl/sand_defs.vh` to match target FPGA/sim.
- Seed job planes via CSR or seed port (plane 0 default); pointer swap flips per frame.
- Program opcodes, constants, microcode, unit weights via CSR writes.
- For behavioural demos, describe high-level knobs in YAML, let `sand_configurator` mint include headers + source manifests, then tweak with CLI overrides as needed.
- For broader synthesis profiles, drive `sand_dynamic_configurator`: run `python3 -m tools.sand_dynamic_configurator list features` to inspect knobs, craft a YAML profile (e.g. `tools/sample_dynamic_config.yaml`), then `python3 -m tools.sand_dynamic_configurator build <config> --output <dir>` to produce defines, manifests, and type headers ready for `iverilog`/FPGA flows.
- Monitor `job_done`, `CSR_ADAPT_STATUS`, `CSR_ADAPT_BUDGET` to track activity and scheduler decisions.
- Use example scripts for regression demos (`python3 examples/.../run.py`); requires iverilog/vvp in PATH.

HOUSEKEEPING NOTES:
- README.md: extended architecture narrative and usage guidance.
- LICENSE: MIT 2025 Riccardo Cecchini.
- No dedicated test suite beyond examples; consider extending examples/tests when modifying RTL.

REMINDER_LOOP:
- After any AI-driven repository modification: re-evaluate affected modules, update AI_REFERENCE.md accordingly, confirm reminder stays prominent.
