"""Run the Galton board example using the adaptive sand engine."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
import pathlib
import random
import re
import sys
from typing import Dict, List

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools import sand_runner


def _parse_macro_int(path: pathlib.Path, name: str, default: int) -> int:
    pattern = re.compile(rf"`define\\s+{name}\\s+([0-9']+)" )
    for line in path.read_text().splitlines():
        match = pattern.match(line.strip())
        if match:
            token = match.group(1)
            token = token.replace("'", "")
            return int(token, 0)
    return default


def _parse_galton_output(stdout: str) -> Dict[int, int]:
    bins: Dict[int, int] = {}
    for line in stdout.splitlines():
        if line.startswith("GALTON.bin["):
            idx_str, value_str = line.split("=", 1)
            idx = int(idx_str[idx_str.find("[") + 1: idx_str.find("]")])
            bins[idx] = int(value_str)
    if not bins:
        raise sand_runner.SandToolError("Galton simulation did not emit any bins")
    return dict(sorted(bins.items()))


def _build_example(repo_root: pathlib.Path, output: pathlib.Path) -> pathlib.Path:
    sources = [repo_root / "examples" / "galton_board" / "galton_board_tb.v"]

    build_cfg = sand_runner.IcarusBuildConfig(
        sources=sources,
        output=output,
        include_dirs=[repo_root / "rtl"],
    )
    return sand_runner.compile_icarus(build_cfg)


def _sample_counts(probabilities: List[float], samples: int) -> Counter:
    population = list(range(len(probabilities)))
    draws = random.choices(population, weights=probabilities, k=samples)
    return Counter(draws)


def run_example(left_pct: int, right_pct: int, board_w: int, board_h: int,
                gaussian_samples: int, json_path: pathlib.Path | None) -> None:
    repo_root = REPO_ROOT
    defs_path = repo_root / "rtl" / "sand_defs.vh"
    frac_w = _parse_macro_int(defs_path, "FRAC_W", 8)

    build_dir = repo_root / "examples" / "galton_board" / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    vvp_path = build_dir / "galton_board.vvp"

    _build_example(repo_root, vvp_path)

    plusargs = {
        "LEFT_PCT": left_pct,
        "RIGHT_PCT": right_pct,
        "BOARD_W": board_w,
        "BOARD_H": board_h,
    }

    stdout = sand_runner.run_vvp(vvp_path, plusargs=plusargs)
    bins_q = _parse_galton_output(stdout)

    # Convert to probability mass
    scale = float(1 << frac_w)
    probabilities = [(idx, value / scale) for idx, value in bins_q.items()]
    total_mass = sum(p for _, p in probabilities)

    print("Galton board steady-state distribution (probabilities sum to {:.6f})".format(total_mass))
    peak = max(probabilities, key=lambda item: item[1])[1]
    for idx, prob in probabilities:
        if prob > 0:
            scaled = max(1, int(prob / peak * 48))
            bar = "#" * scaled
        else:
            bar = ""
        print(f"  bin {idx:02d}: prob={prob:.6f} |{bar}")

    results_payload = {
        "probabilities": {str(idx): prob for idx, prob in probabilities},
        "frac_w": frac_w,
    }

    if gaussian_samples > 0:
        probs_only = [p for _, p in probabilities]
        counts = _sample_counts(probs_only, gaussian_samples)
        print(f"\nRandom sampling ({gaussian_samples} balls)")
        max_count = max(counts.values()) if counts else 1
        for idx, prob in probabilities:
            count = counts.get(idx, 0)
            bar = "*" * max(1, int(count / max_count * 48)) if count else ""
            print(f"  bin {idx:02d}: count={count:6d} |{bar}")
        results_payload["samples"] = gaussian_samples
        results_payload["sample_counts"] = {str(idx): counts.get(idx, 0) for idx, _ in probabilities}

    if json_path:
        json_path.write_text(json.dumps(results_payload, indent=2))
        print(f"\nSaved detailed data to {json_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Galton board demonstration on the Sand engine")
    parser.add_argument("--left", type=int, default=500,
                        help="Left split percentage in thousandths (default: 500)")
    parser.add_argument("--right", type=int, default=-1,
                        help="Right split percentage in thousandths (default: complement of left)")
    parser.add_argument("--board-width", type=int, default=15,
                        help="Active board width (must be <= sand WIDTH)")
    parser.add_argument("--board-height", type=int, default=16,
                        help="Active board height (must be <= sand HEIGHT)")
    parser.add_argument("--samples", type=int, default=1024,
                        help="Number of random balls to draw for gaussian illustration (0 to skip)")
    parser.add_argument("--json", type=pathlib.Path,
                        help="Optional path to dump probabilities and sample counts as JSON")
    parser.add_argument("--seed", type=int, help="Random seed for reproducible sampling")

    args = parser.parse_args()

    if args.right < 0:
        right_pct = max(0, 1000 - args.left)
    else:
        right_pct = args.right

    if args.left < 0:
        args.left = 0
    total = args.left + right_pct
    if total > 1000:
        right_pct = max(0, 1000 - args.left)

    if args.seed is not None:
        random.seed(args.seed)

    run_example(args.left, right_pct, args.board_width, args.board_height,
                args.samples, args.json)


if __name__ == "__main__":
    main()
