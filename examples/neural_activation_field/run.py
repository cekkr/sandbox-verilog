"""Run the neural activation field behavioural demo.""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Dict, Iterable, List, Tuple

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools import sand_configurator, sand_runner


WINDOW_RE = re.compile(
    r"NAF\.window_w=(\d+) window_h=(\d+) window_d=(\d+) pattern_id=(\d+) iterations=(\d+)"
)
CFG_AGG_RE = re.compile(
    r"NAF\.config\.self_gain_q=(-?\d+) planar_gain_q=(-?\d+) vertical_gain_q=(-?\d+) bias_q=(-?\d+)"
)
CFG_CTRL_RE = re.compile(
    r"NAF\.config\.feedback_q=(-?\d+) damp_q=(-?\d+) learning_q=(-?\d+) target_q=(-?\d+)"
)
CFG_READOUT_RE = re.compile(
    r"NAF\.readout\.edge_gain_q=(-?\d+) raw_gain_q=(-?\d+) bias_q=(-?\d+) threshold_q=(-?\d+)"
)
ITER_RE = re.compile(
    r"NAF\.iter\[(\d+)\].bias_q=(-?\d+) mean_top_q=(-?\d+) error_q=(-?\d+)"
)
ACT_RE = re.compile(r"NAF\.act\[z=(\d+),y=(\d+),x=(\d+)\]=(-?\d+)")
READ_RAW_RE = re.compile(r"NAF\.readout\.raw\[(\d+),(\d+)\]=(-?\d+)")
READ_RELU_RE = re.compile(r"NAF\.readout\.relu\[(\d+),(\d+)\]=(-?\d+)")
READ_FIRE_RE = re.compile(r"NAF\.readout\.fire\[(\d+),(\d+)\]=(-?\d+)")
SUMMARY_TOP_RE = re.compile(
    r"NAF\.summary\.top_sum_q=(-?\d+) top_mean_q=(-?\d+) top_active=(\d+)"
)
SUMMARY_READ_RE = re.compile(
    r"NAF\.summary\.readout_fire=(\d+) readout_mean_q=(-?\d+) final_bias_q=(-?\d+) error_q=(-?\d+)"
)


def _parse_macro_int(path: pathlib.Path, name: str, default: int) -> int:
    pattern = re.compile(rf"`define\s+{name}\s+([0-9']+)")
    for line in path.read_text().splitlines():
        match = pattern.match(line.strip())
        if match:
            token = match.group(1).replace("'", "")
            return int(token, 0)
    return default


def _build_example(
    repo_root: pathlib.Path,
    output: pathlib.Path,
    *, 
    include_dirs: Iterable[pathlib.Path],
    extra_sources: Iterable[pathlib.Path],
) -> pathlib.Path:
    sources = [
        repo_root / "examples" / "neural_activation_field" / "neural_activation_field_tb.v",
        *(repo_root / src for src in extra_sources),
    ]
    build_cfg = sand_runner.IcarusBuildConfig(
        sources=sources,
        output=output,
        include_dirs=include_dirs,
    )
    return sand_runner.compile_icarus(build_cfg)


def _dict3d_to_volume(
    data: Dict[Tuple[int, int, int], int],
    depth: int,
    height: int,
    width: int,
    default: int = 0,
) -> List[List[List[int]]]:
    volume = [
        [[default for _ in range(width)] for _ in range(height)] for _ in range(depth)
    ]
    for (z, y, x), value in data.items():
        if 0 <= z < depth and 0 <= y < height and 0 <= x < width:
            volume[z][y][x] = value
    return volume


def _dict2d_to_grid(
    data: Dict[Tuple[int, int], int], height: int, width: int, default: int = 0
) -> List[List[int]]:
    grid = [[default for _ in range(width)] for _ in range(height)]
    for (y, x), value in data.items():
        if 0 <= y < height and 0 <= x < width:
            grid[y][x] = value
    return grid


def _parse_sim_output(stdout: str) -> Dict[str, object]:
    width: int | None = None
    height: int | None = None
    depth: int | None = None
    pattern_id: int | None = None
    iterations: int | None = None

    cfg_agg: Dict[str, int] = {}
    cfg_ctrl: Dict[str, int] = {}
    cfg_readout: Dict[str, int] = {}

    iter_steps: Dict[int, Dict[str, int]] = {}
    act_vals: Dict[Tuple[int, int, int], int] = {}
    read_raw: Dict[Tuple[int, int], int] = {}
    read_relu: Dict[Tuple[int, int], int] = {}
    read_fire: Dict[Tuple[int, int], int] = {}
    summary: Dict[str, int] = {}

    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue

        match = WINDOW_RE.match(line)
        if match:
            width = int(match.group(1))
            height = int(match.group(2))
            depth = int(match.group(3))
            pattern_id = int(match.group(4))
            iterations = int(match.group(5))
            continue

        match = CFG_AGG_RE.match(line)
        if match:
            cfg_agg = {
                "self_gain": int(match.group(1)),
                "planar_gain": int(match.group(2)),
                "vertical_gain": int(match.group(3)),
                "bias": int(match.group(4)),
            }
            continue

        match = CFG_CTRL_RE.match(line)
        if match:
            cfg_ctrl = {
                "feedback": int(match.group(1)),
                "damp": int(match.group(2)),
                "learning": int(match.group(3)),
                "target": int(match.group(4)),
            }
            continue

        match = CFG_READOUT_RE.match(line)
        if match:
            cfg_readout = {
                "edge_gain": int(match.group(1)),
                "raw_gain": int(match.group(2)),
                "bias": int(match.group(3)),
                "threshold": int(match.group(4)),
            }
            continue

        match = ITER_RE.match(line)
        if match:
            idx = int(match.group(1))
            iter_steps[idx] = {
                "bias_q": int(match.group(2)),
                "mean_top_q": int(match.group(3)),
                "error_q": int(match.group(4)),
            }
            continue

        match = ACT_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
            act_vals[coord] = int(match.group(4))
            continue

        match = READ_RAW_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            read_raw[coord] = int(match.group(3))
            continue

        match = READ_RELU_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            read_relu[coord] = int(match.group(3))
            continue

        match = READ_FIRE_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            read_fire[coord] = int(match.group(3))
            continue

        match = SUMMARY_TOP_RE.match(line)
        if match:
            summary.update(
                {
                    "top_sum_q": int(match.group(1)),
                    "top_mean_q": int(match.group(2)),
                    "top_active": int(match.group(3)),
                }
            )
            continue

        match = SUMMARY_READ_RE.match(line)
        if match:
            summary.update(
                {
                    "readout_fire": int(match.group(1)),
                    "readout_mean_q": int(match.group(2)),
                    "final_bias_q": int(match.group(3)),
                    "error_q": int(match.group(4)),
                }
            )
            continue

    if width is None or height is None or depth is None or iterations is None:
        raise sand_runner.SandToolError("Simulation did not report volume parameters")

    volume = _dict3d_to_volume(act_vals, depth, height, width)
    read_raw_grid = _dict2d_to_grid(read_raw, height, width)
    read_relu_grid = _dict2d_to_grid(read_relu, height, width)
    read_fire_grid = _dict2d_to_grid(read_fire, height, width)

    return {
        "width": width,
        "height": height,
        "depth": depth,
        "pattern_id": pattern_id,
        "iterations": iterations,
        "config_agg": cfg_agg,
        "config_ctrl": cfg_ctrl,
        "config_readout": cfg_readout,
        "iterations_log": iter_steps,
        "activations": volume,
        "readout_raw": read_raw_grid,
        "readout_relu": read_relu_grid,
        "readout_fire": read_fire_grid,
        "summary": summary,
    }


def _scale_grid(grid: List[List[int]], frac_bits: int) -> List[List[float]]:
    return [
        [sand_runner.q_to_float(value, frac_bits) for value in row] for row in grid
    ]


def _scale_volume(volume: List[List[List[int]]], frac_bits: int) -> List[List[List[float]]]:
    return [
        [
            [sand_runner.q_to_float(value, frac_bits) for value in row]
            for row in layer
        ]
        for layer in volume
    ]


def _render_heatmap(grid: List[List[float]], palette: str = " .:-=+*#%@") -> List[str]:
    height = len(grid)
    width = len(grid[0]) if height else 0
    max_val = max((max(row) for row in grid if row), default=0.0)
    min_val = min((min(row) for row in grid if row), default=0.0)
    span = max_val - min_val
    if abs(span) < 1e-9:
        span = 1.0

    rows: List[str] = []
    palette_last = len(palette) - 1
    for y in range(height):
        chars: List[str] = []
        for x in range(width):
            value = grid[y][x]
            norm = (value - min_val) / span
            idx = min(palette_last, max(0, int(norm * palette_last + 0.5)))
            chars.append(palette[idx])
        rows.append("".join(chars))
    return rows


def _render_binary(grid: List[List[int]]) -> List[str]:
    return ["".join("#" if cell else "." for cell in row) for row in grid]


def run_example(
    params: sand_configurator.ActivationFieldParams,
    json_path: pathlib.Path | None,
    image_file: pathlib.Path | None,
) -> None:
    repo_root = REPO_ROOT
    defs_path = repo_root / "rtl" / "sand_defs.vh"
    frac_w = _parse_macro_int(defs_path, "FRAC_W", 8)

    build_dir = repo_root / "examples" / "neural_activation_field" / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    header_path = build_dir / "neural_activation_field_config.vh"
    sand_configurator.write_activation_field_header(params, header_path)

    vvp_path = build_dir / "neural_activation_field.vvp"
    include_dirs = [
        build_dir,
        repo_root / "examples" / "neural_activation_field",
        repo_root / "rtl",
    ]
    extra_sources = sand_configurator.required_sources(params.circuits)
    _build_example(
        repo_root,
        vvp_path,
        include_dirs=include_dirs,
        extra_sources=extra_sources,
    )

    plusargs = {
        "WINDOW_W": params.window_w,
        "WINDOW_H": params.window_h,
        "WINDOW_D": params.window_d,
        "PATTERN_ID": params.pattern_id,
        "ITERATIONS": params.iterations,
        "SELF_GAIN": params.self_gain_pct,
        "PLANAR_GAIN": params.planar_gain_pct,
        "VERT_GAIN": params.vertical_gain_pct,
        "BIAS_PCT": params.bias_pct,
        "DAMP_PCT": params.damp_pct,
        "LEARN_PCT": params.learning_pct,
        "TARGET_PCT": params.target_pct,
        "READ_EDGE_PCT": params.read_edge_pct,
        "READ_RAW_PCT": params.read_raw_pct,
        "READ_BIAS_PCT": params.read_bias_pct,
        "READ_THRESH_PCT": params.read_threshold_pct,
    }

    if image_file:
        plusargs["IMAGE_FILE"] = str(image_file)

    for i in range(params.window_d):
        plusargs[f"FEEDBACK_L{i}_PCT"] = params.feedback_pct

    stdout = sand_runner.run_vvp(vvp_path, plusargs=plusargs)
    sim_data = _parse_sim_output(stdout)

    activations_q = sim_data["activations"]
    readout_raw_q = sim_data["readout_raw"]
    readout_relu_q = sim_data["readout_relu"]
    readout_fire = sim_data["readout_fire"]
    summary_q = sim_data["summary"]
    iter_logs = sim_data["iterations_log"]

    activations = _scale_volume(activations_q, frac_w)
    readout_raw = _scale_grid(readout_raw_q, frac_w)
    readout_relu = _scale_grid(readout_relu_q, frac_w)

    top_mean = sand_runner.q_to_float(summary_q.get("top_mean_q", 0), frac_w)
    readout_mean = sand_runner.q_to_float(summary_q.get("readout_mean_q", 0), frac_w)
    final_bias = sand_runner.q_to_float(summary_q.get("final_bias_q", 0), frac_w)
    final_error = sand_runner.q_to_float(summary_q.get("error_q", 0), frac_w)

    print(
        f"Neural activation field — pattern {params.pattern} ({params.pattern_id}), "
        f"volume {params.window_w}×{params.window_h}×{params.window_d}, "
        f"{params.iterations} iterations"
    )
    print(
        f"  Top-layer mean activation: {top_mean:.4f} "
        f"(active cells: {summary_q.get('top_active', 0)})"
    )
    print(
        f"  Readout: {summary_q.get('readout_fire', 0)} spikes, "
        f"mean ReLU {readout_mean:.4f}, final bias {final_bias:.4f}, error {final_error:.4f}"
    )

    for idx, log in sorted(iter_logs.items()):
        bias_f = sand_runner.q_to_float(log["bias_q"], frac_w)
        mean_f = sand_runner.q_to_float(log["mean_top_q"], frac_w)
        err_f = sand_runner.q_to_float(log["error_q"], frac_w)
        print(
            f"  Iter {idx}: bias {bias_f:.4f}, mean {mean_f:.4f}, error {err_f:.4f}"
        )

    print("\nActivation slices (softsign response):")
    for z, layer in enumerate(activations):
        print(f"  Layer {z}:")
        for row in _render_heatmap(layer):
            print("    " + row)

    print("\nReadout raw potential:")
    for row in _render_heatmap(readout_raw):
        print("  " + row)

    print("\nReadout ReLU:")
    for row in _render_heatmap(readout_relu):
        print("  " + row)

    print("\nReadout fire mask (#=spike):")
    for row in _render_binary(readout_fire):
        print("  " + row)

    if json_path:
        payload = {
            "volume": {
                "width": params.window_w,
                "height": params.window_h,
                "depth": params.window_d,
            },
            "pattern": params.pattern,
            "pattern_id": params.pattern_id,
            "iterations": params.iterations,
            "frac_bits": frac_w,
            "config": {
                "agg": sim_data["config_agg"],
                "ctrl": sim_data["config_ctrl"],
                "readout": sim_data["config_readout"],
            },
            "iterations": iter_logs,
            "activations_q": activations_q,
            "readout_raw_q": readout_raw_q,
            "readout_relu_q": readout_relu_q,
            "readout_fire": readout_fire,
            "summary": summary_q,
        }
        json_path.write_text(json.dumps(payload, indent=2))
        print(f"\nSaved raw data to {json_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="3D neural activation field demo atop the Sand toolbox"
    )
    parser.add_argument(
        "--config", type=pathlib.Path, help="Optional YAML/JSON config for the volume"
    )
    parser.add_argument("--window-width", type=int, help="Override window width")
    parser.add_argument("--window-height", type=int, help="Override window height")
    parser.add_argument("--window-depth", type=int, help="Override window depth")
    parser.add_argument(
        "--pattern",
        choices=list(sand_configurator.ACTIVATION_PATTERN_TO_ID.keys()),  # type: ignore[attr-defined]
        help="Override base stimulation pattern",
    )
    parser.add_argument("--image-file", type=pathlib.Path, help="Path to a hex file containing the image data")
    parser.add_argument("--iterations", type=int, help="Override iteration count")
    parser.add_argument("--self-gain", type=float, help="Override self gain (0..1)")
    parser.add_argument("--planar-gain", type=float, help="Override planar gain (0..1)")
    parser.add_argument("--vertical-gain", type=float, help="Override vertical gain")
    parser.add_argument("--bias", type=float, help="Override aggregator bias")
    parser.add_argument("--damp", type=float, help="Override damping gain")
    parser.add_argument("--learning-rate", type=float, help="Override learning rate")
    parser.add_argument("--target", type=float, help="Override target activation level")
    parser.add_argument("--readout-edge", type=float, help="Override readout edge gain")
    parser.add_argument("--readout-raw", type=float, help="Override readout raw gain")
    parser.add_argument("--readout-bias", type=float, help="Override readout bias")
    parser.add_argument(
        "--readout-threshold", type=float, help="Override readout threshold"
    )
    parser.add_argument("--json", type=pathlib.Path, help="Dump raw Q data as JSON")

    args, remaining_args = parser.parse_known_args()

    params = sand_configurator.resolve_activation_field_params(args.config)

    if args.window_width is not None:
        params = params.override(window_w=args.window_width)
    if args.window_height is not None:
        params = params.override(window_h=args.window_height)
    if args.window_depth is not None:
        params = params.override(window_d=args.window_depth)
    if args.pattern is not None:
        params = params.override(pattern=args.pattern.lower())
    if args.iterations is not None:
        params = params.override(iterations=args.iterations)
    if args.self_gain is not None:
        params = params.override(self_gain_pct=int(round(args.self_gain * 1000.0)))
    if args.planar_gain is not None:
        params = params.override(planar_gain_pct=int(round(args.planar_gain * 1000.0)))
    if args.vertical_gain is not None:
        params = params.override(vertical_gain_pct=int(round(args.vertical_gain * 1000.0)))
    if args.bias is not None:
        params = params.override(bias_pct=int(round(args.bias * 1000.0)))
    if args.damp is not None:
        params = params.override(damp_pct=int(round(args.damp * 1000.0)))
    if args.learning_rate is not None:
        params = params.override(learning_pct=int(round(args.learning_rate * 1000.0)))
    if args.target is not None:
        params = params.override(target_pct=int(round(args.target * 1000.0)))
    if args.readout_edge is not None:
        params = params.override(read_edge_pct=int(round(args.readout_edge * 1000.0)))
    if args.readout_raw is not None:
        params = params.override(read_raw_pct=int(round(args.readout_raw * 1000.0)))
    if args.readout_bias is not None:
        params = params.override(read_bias_pct=int(round(args.readout_bias * 1000.0)))
    if args.readout_threshold is not None:
        params = params.override(read_threshold_pct=int(round(args.readout_threshold * 1000.0)))

    # Handle per-layer feedback gains
    for i in range(params.window_d):
        arg_name = f"--feedback-l{i}-pct"
        if arg_name in remaining_args:
            idx = remaining_args.index(arg_name)
            val = int(remaining_args[idx+1])
            params = params.override(feedback_pct=val, layer=i)

    run_example(params=params, json_path=args.json, image_file=args.image_file)


if __name__ == "__main__":
    main()