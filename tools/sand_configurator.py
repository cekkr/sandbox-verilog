"""
Configuration helpers that bridge YAML/JSON descriptions into Verilog headers.

These utilities keep the behavioural examples focused on algorithmic structure
while Python glue handles code generation and source selection.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import pathlib
from typing import Any, Dict, List, Mapping, Sequence

try:  # pragma: no cover - yaml is optional
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore


class SandConfigError(RuntimeError):
    """Raised when configuration parsing fails."""


@dataclass
class NeuralEdgeParams:
    window_w: int
    window_h: int
    pattern: str
    pattern_id: int
    edge_gain_pct: int
    raw_gain_pct: int
    bias_pct: int
    threshold_pct: int
    circuits: Sequence[str]

    def override(
        self,
        *,
        window_w: int | None = None,
        window_h: int | None = None,
        pattern: str | None = None,
        edge_gain_pct: int | None = None,
        raw_gain_pct: int | None = None,
        bias_pct: int | None = None,
        threshold_pct: int | None = None,
    ) -> "NeuralEdgeParams":
        """Return a copy with selected fields overridden."""
        return NeuralEdgeParams(
            window_w=window_w if window_w is not None else self.window_w,
            window_h=window_h if window_h is not None else self.window_h,
            pattern=pattern if pattern is not None else self.pattern,
            pattern_id=PATTERN_TO_ID[pattern] if pattern is not None else self.pattern_id,
            edge_gain_pct=edge_gain_pct if edge_gain_pct is not None else self.edge_gain_pct,
            raw_gain_pct=raw_gain_pct if raw_gain_pct is not None else self.raw_gain_pct,
            bias_pct=bias_pct if bias_pct is not None else self.bias_pct,
            threshold_pct=threshold_pct if threshold_pct is not None else self.threshold_pct,
            circuits=self.circuits,
        )


CIRCUIT_LIBRARY: Mapping[str, Dict[str, Any]] = {
    "edge_l1": {
        "source": pathlib.Path("rtl/circuits/sand_circuit_edge_l1.v"),
        "module": "sand_circuit_edge_l1",
        "description": "|E-W| + |S-N| edge magnitude core",
    },
    "neuron_relu": {
        "source": pathlib.Path("rtl/circuits/sand_circuit_neuron_relu.v"),
        "module": "sand_circuit_neuron_relu",
        "description": "Edge/raw combiner with ReLU and threshold flag",
    },
}

PATTERN_TO_ID = {
    "cross": 0,
    "ramp": 1,
    "checker": 2,
    "diag": 3,
}

DEFAULT_NEURAL_EDGE = {
    "window": {"width": 8, "height": 8},
    "pattern": "cross",
    "gains": {"edge": 0.7, "raw": 0.3},
    "bias": -0.25,
    "threshold": 0.5,
    "circuits": ["edge_l1", "neuron_relu"],
}


def _load_yaml_or_json(path: pathlib.Path) -> Dict[str, Any]:
    text = path.read_text()
    data: Dict[str, Any]
    if yaml is not None:  # pragma: no branch
        loaded = yaml.safe_load(text)  # type: ignore[assignment]
    else:
        loaded = json.loads(text)
    if not isinstance(loaded, dict):
        raise SandConfigError("Top-level configuration must be a mapping")
    return loaded


def _as_float(value: Any, *, field: str) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    raise SandConfigError(f"Field '{field}' must be numeric")


def _thousandths(value: float) -> int:
    return int(round(value * 1000.0))


def resolve_neural_edge_params(config_path: pathlib.Path | None) -> NeuralEdgeParams:
    """
    Merge defaults with an optional YAML/JSON override and return a structured view.
    """
    merged = json.loads(json.dumps(DEFAULT_NEURAL_EDGE))  # cheap deep copy
    if config_path:
        user_cfg = _load_yaml_or_json(config_path)
        if "neural_edge_slice" in user_cfg:
            section = user_cfg["neural_edge_slice"]
            if not isinstance(section, dict):
                raise SandConfigError("'neural_edge_slice' must be a mapping")
        else:
            section = user_cfg

        if "window" in section:
            if not isinstance(section["window"], Mapping):
                raise SandConfigError("'window' must be a mapping")
            merged["window"].update(section["window"])  # type: ignore[arg-type]
        if "pattern" in section and section["pattern"] is not None:
            merged["pattern"] = section["pattern"]
        if "gains" in section:
            if not isinstance(section["gains"], Mapping):
                raise SandConfigError("'gains' must be a mapping")
            merged["gains"].update(section["gains"])  # type: ignore[arg-type]
        for field in ("bias", "threshold"):
            if field in section and section[field] is not None:
                merged[field] = section[field]
        if "circuits" in section and section["circuits"] is not None:
            if not isinstance(section["circuits"], (list, tuple)):
                raise SandConfigError("'circuits' must be a list")
            merged["circuits"] = list(section["circuits"])
        # Optional direct thousandth overrides.
        for field in ("edge_gain_pct", "raw_gain_pct", "bias_pct", "threshold_pct"):
            if field in section and section[field] is not None:
                merged[field] = int(section[field])

    try:
        window_w = int(merged["window"]["width"])
        window_h = int(merged["window"]["height"])
    except (KeyError, TypeError, ValueError) as exc:
        raise SandConfigError("'window' must define integer width/height") from exc

    pattern = str(merged["pattern"]).lower()
    if pattern not in PATTERN_TO_ID:
        raise SandConfigError(
            f"Unknown pattern '{pattern}'. Options: {', '.join(sorted(PATTERN_TO_ID))}"
        )

    if "edge_gain_pct" in merged:
        edge_gain_pct = int(merged["edge_gain_pct"])
    else:
        edge_gain_pct = _thousandths(_as_float(merged["gains"]["edge"], field="gains.edge"))

    if "raw_gain_pct" in merged:
        raw_gain_pct = int(merged["raw_gain_pct"])
    else:
        raw_gain_pct = _thousandths(_as_float(merged["gains"]["raw"], field="gains.raw"))

    if "bias_pct" in merged:
        bias_pct = int(merged["bias_pct"])
    else:
        bias_pct = _thousandths(_as_float(merged["bias"], field="bias"))

    if "threshold_pct" in merged:
        threshold_pct = int(merged["threshold_pct"])
    else:
        threshold_pct = _thousandths(_as_float(merged["threshold"], field="threshold"))

    circuits = list(merged["circuits"])
    for name in circuits:
        if name not in CIRCUIT_LIBRARY:
            raise SandConfigError(
                f"Unknown circuit '{name}'. Known: {', '.join(sorted(CIRCUIT_LIBRARY))}"
            )

    return NeuralEdgeParams(
        window_w=window_w,
        window_h=window_h,
        pattern=pattern,
        pattern_id=PATTERN_TO_ID[pattern],
        edge_gain_pct=edge_gain_pct,
        raw_gain_pct=raw_gain_pct,
        bias_pct=bias_pct,
        threshold_pct=threshold_pct,
        circuits=circuits,
    )


def write_neural_edge_header(params: NeuralEdgeParams, output: pathlib.Path) -> None:
    """Emit the include file consumed by the behavioural testbench."""
    lines = [
        "// Auto-generated by sand_configurator.py",
        "`ifndef NEURAL_EDGE_SLICE_CONFIG_VH",
        "`define NEURAL_EDGE_SLICE_CONFIG_VH",
        f"localparam integer NES_WINDOW_W_DEFAULT   = {params.window_w};",
        f"localparam integer NES_WINDOW_H_DEFAULT   = {params.window_h};",
        f"localparam integer NES_PATTERN_ID_DEFAULT = {params.pattern_id};",
        f"localparam integer NES_EDGE_GAIN_PCT      = {params.edge_gain_pct};",
        f"localparam integer NES_RAW_GAIN_PCT       = {params.raw_gain_pct};",
        f"localparam integer NES_BIAS_PCT           = {params.bias_pct};",
        f"localparam integer NES_THRESHOLD_PCT      = {params.threshold_pct};",
        "`endif  // NEURAL_EDGE_SLICE_CONFIG_VH",
        "",
    ]
    output.write_text("\n".join(lines))


def required_sources(params: NeuralEdgeParams) -> List[pathlib.Path]:
    """Return library sources needed by the requested circuits."""
    seen: set[pathlib.Path] = set()
    sources: List[pathlib.Path] = []
    for name in params.circuits:
        src = CIRCUIT_LIBRARY[name]["source"]
        if src not in seen:
            seen.add(src)
            sources.append(src)
    return sources
