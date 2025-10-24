"""Run the neural edge detector slice example on top of the Sand toolbox."""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sys
from typing import Dict, Iterable, List, Tuple

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools import sand_configurator, sand_runner


WINDOW_RE = re.compile(r"NEURAL\.window_w=(\d+) window_h=(\d+) pattern_id=(\d+)")
CONFIG_RE = re.compile(
    r"NEURAL\.config\.edge_gain_q=(-?\d+) raw_gain_q=(-?\d+) bias_q=(-?\d+) threshold_q=(-?\d+)"
)
EDGE_RE = re.compile(r"EDGE\.pixel\[(\d+),(\d+)\]=(-?\d+)")
RAW_RE = re.compile(r"NEURON\.raw\[(\d+),(\d+)\]=(-?\d+)")
RELU_RE = re.compile(r"NEURON\.relu\[(\d+),(\d+)\]=(-?\d+)")
FIRE_RE = re.compile(r"NEURON\.fire\[(\d+),(\d+)\]=(-?\d+)")
SUMMARY_RE = re.compile(
    r"NEURON\.summary\.total_edge=(-?\d+) active_pixels=(\d+) total_relu=(-?\d+)"
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
        repo_root / "examples" / "neural_edge_slice" / "neural_edge_slice_tb.v",
        *(repo_root / src for src in extra_sources),
    ]
    build_cfg = sand_runner.IcarusBuildConfig(
        sources=sources,
        output=output,
        include_dirs=include_dirs,
    )
    return sand_runner.compile_icarus(build_cfg)


def _dict_to_grid(
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
    pattern_id: int | None = None
    config_q: Dict[str, int] = {}
    edge_vals: Dict[Tuple[int, int], int] = {}
    raw_vals: Dict[Tuple[int, int], int] = {}
    relu_vals: Dict[Tuple[int, int], int] = {}
    fire_vals: Dict[Tuple[int, int], int] = {}
    summary_q: Dict[str, int] = {}

    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue

        match = WINDOW_RE.match(line)
        if match:
            width = int(match.group(1))
            height = int(match.group(2))
            pattern_id = int(match.group(3))
            continue

        match = CONFIG_RE.match(line)
        if match:
            config_q = {
                "edge_gain": int(match.group(1)),
                "raw_gain": int(match.group(2)),
                "bias": int(match.group(3)),
                "threshold": int(match.group(4)),
            }
            continue

        match = EDGE_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            edge_vals[coord] = int(match.group(3))
            continue

        match = RAW_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            raw_vals[coord] = int(match.group(3))
            continue

        match = RELU_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            relu_vals[coord] = int(match.group(3))
            continue

        match = FIRE_RE.match(line)
        if match:
            coord = (int(match.group(1)), int(match.group(2)))
            fire_vals[coord] = int(match.group(3))
            continue

        match = SUMMARY_RE.match(line)
        if match:
            summary_q = {
                "total_edge": int(match.group(1)),
                "active_pixels": int(match.group(2)),
                "total_relu": int(match.group(3)),
            }
            continue

    if width is None or height is None:
        raise sand_runner.SandToolError("Simulation did not report window dimensions")

    return {
        "width": width,
        "height": height,
        "pattern_id": pattern_id,
        "config_q": config_q,
        "edge": _dict_to_grid(edge_vals, height, width),
        "raw": _dict_to_grid(raw_vals, height, width),
        "relu": _dict_to_grid(relu_vals, height, width),
        "fire": _dict_to_grid(fire_vals, height, width),
        "summary_q": summary_q,
    }


def _scale_grid(grid: List[List[int]], frac_bits: int) -> List[List[float]]:
    return [
        [sand_runner.q_to_float(value, frac_bits) for value in row] for row in grid
    ]


def _render_heatmap(grid: List[List[float]], palette: str = " .:-=+*#%@" ) -> List[str]:
    height = len(grid)
    width = len(grid[0]) if height else 0
    max_val = max((max(row) for row in grid if row), default=0.0)
    min_val = min((min(row) for row in grid if row), default=0.0)
    span = max_val - min_val
    if math.isclose(span, 0.0, abs_tol=1e-9):
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
    params: sand_configurator.NeuralEdgeParams,
    json_path: pathlib.Path | None,
) -> None:
    repo_root = REPO_ROOT
    defs_path = repo_root / "rtl" / "sand_defs.vh"
    frac_w = _parse_macro_int(defs_path, "FRAC_W", 8)

    build_dir = repo_root / "examples" / "neural_edge_slice" / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    header_path = build_dir / "neural_edge_slice_config.vh"
    sand_configurator.write_neural_edge_header(params, header_path)

    vvp_path = build_dir / "neural_edge_slice.vvp"

    include_dirs = [
        build_dir,
        repo_root / "examples" / "neural_edge_slice",
        repo_root / "rtl",
    ]
    extra_sources = sand_configurator.required_sources(params)
    _build_example(
        repo_root,
        vvp_path,
        include_dirs=include_dirs,
        extra_sources=extra_sources,
    )

    plusargs = {
        "WINDOW_W": params.window_w,
        "WINDOW_H": params.window_h,
        "PATTERN_ID": params.pattern_id,
        "EDGE_GAIN": params.edge_gain_pct,
        "RAW_GAIN": params.raw_gain_pct,
        "BIAS_PCT": params.bias_pct,
        "THRESH_PCT": params.threshold_pct,
    }

    stdout = sand_runner.run_vvp(vvp_path, plusargs=plusargs)
    sim_data = _parse_sim_output(stdout)

    edge_q = sim_data["edge"]
    raw_q = sim_data["raw"]
    relu_q = sim_data["relu"]
    fire = sim_data["fire"]

    edge = _scale_grid(edge_q, frac_w)
    raw = _scale_grid(raw_q, frac_w)
    relu = _scale_grid(relu_q, frac_w)

    total_edge = sim_data["summary_q"].get("total_edge", 0)
    active_pixels = sim_data["summary_q"].get("active_pixels", 0)
    total_relu = sim_data["summary_q"].get("total_relu", 0)

    window_cells = params.window_w * params.window_h
    active_fraction = active_pixels / float(window_cells)
    avg_edge = sand_runner.q_to_float(total_edge, frac_w) / window_cells
    avg_relu = (
        sand_runner.q_to_float(total_relu, frac_w) / active_pixels
        if active_pixels
        else 0.0
    )

    print(
        f"Neural edge slice — pattern {params.pattern} ({params.pattern_id}), "
        f"window {params.window_w}×{params.window_h}"
    )
    print(f"  Active neurons: {active_pixels}/{window_cells} "
          f"({active_fraction:.1%})")
    print(f"  Mean edge magnitude: {avg_edge:.4f}")
    print(f"  Mean ReLU activation (active only): {avg_relu:.4f}")

    edge_map = _render_heatmap(edge)
    relu_map = _render_heatmap(relu)
    fire_map = _render_binary(fire)

    print("\nEdge map (scaled heatmap):")
    for row in edge_map:
        print("  " + row)

    print("\nReLU activations (scaled heatmap):")
    for row in relu_map:
        print("  " + row)

    print("\nBinary neuron firing mask (#=active):")
    for row in fire_map:
        print("  " + row)

    if json_path:
        payload = {
            "window": {"width": params.window_w, "height": params.window_h},
            "pattern": params.pattern,
            "pattern_id": params.pattern_id,
            "config_q": sim_data["config_q"],
            "frac_bits": frac_w,
            "edge_q": edge_q,
            "raw_q": raw_q,
            "relu_q": relu_q,
            "fire": fire,
            "summary_q": sim_data["summary_q"],
        }
        json_path.write_text(json.dumps(payload, indent=2))
        print(f"\nSaved raw data to {json_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Neural edge detector slice demo atop the Sand fixed-point math"
    )
    parser.add_argument("--config", type=pathlib.Path,
                        help="Optional YAML/JSON config for the slice pipeline")
    parser.add_argument("--window-width", type=int,
                        help="Override window width (<= sand WIDTH)")
    parser.add_argument("--window-height", type=int,
                        help="Override window height (<= sand HEIGHT)")
    parser.add_argument("--pattern", choices=list(sand_configurator.PATTERN_TO_ID.keys()),
                        help="Override input field pattern")
    parser.add_argument("--edge-gain", type=float,
                        help="Override edge slice gain (float, e.g. 0.7)")
    parser.add_argument("--raw-gain", type=float,
                        help="Override raw intensity gain (float, e.g. 0.3)")
    parser.add_argument("--bias", type=float,
                        help="Override bias term added to the neuron sum")
    parser.add_argument("--threshold", type=float,
                        help="Override activation threshold for neuron firing")
    parser.add_argument("--json", type=pathlib.Path,
                        help="Optional path to dump raw Q data as JSON")

    args = parser.parse_args()

    params = sand_configurator.resolve_neural_edge_params(args.config)

    if args.window_width is not None:
        params = params.override(window_w=args.window_width)
    if args.window_height is not None:
        params = params.override(window_h=args.window_height)
    if args.pattern is not None:
        params = params.override(pattern=args.pattern.lower())
    if args.edge_gain is not None:
        params = params.override(edge_gain_pct=int(round(args.edge_gain * 1000.0)))
    if args.raw_gain is not None:
        params = params.override(raw_gain_pct=int(round(args.raw_gain * 1000.0)))
    if args.bias is not None:
        params = params.override(bias_pct=int(round(args.bias * 1000.0)))
    if args.threshold is not None:
        params = params.override(threshold_pct=int(round(args.threshold * 1000.0)))

    run_example(params=params, json_path=args.json)


if __name__ == "__main__":
    main()
