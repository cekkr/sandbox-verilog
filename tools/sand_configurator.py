"""
YAML-driven configuration helpers for the Sand example harnesses.

The goal is to keep Verilog edits to a minimum when spinning new behavioural
examples.  Instead, users describe high-level intent in YAML/JSON, and Python
glue generates small include headers plus compilation manifests.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import pathlib
from typing import Any, Dict, List, Mapping, Sequence

try:  # pragma: no cover - optional dependency
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore

CIRCUIT_LIBRARY: Mapping[str, Dict[str, Any]] = {
    "edge_l1": {
        "source": pathlib.Path("rtl/circuits/sand_circuit_edge_l1.v"),
        "module": "sand_circuit_edge_l1",
        "description": "|E-W| + |S-N| edge magnitude slice",
    },
    "neuron_relu": {
        "source": pathlib.Path("rtl/circuits/sand_circuit_neuron_relu.v"),
        "module": "sand_circuit_neuron_relu",
        "description": "Edge/raw combiner with ReLU and fire flag",
    },
}

PATTERN_TO_ID = {
    "cross": 0,
    "ramp": 1,
    "checker": 2,
    "diag": 3,
}

DEFAULT_NEURAL_EDGE_FLOATS = {
    "window": {"width": 8, "height": 8},
    "pattern": "cross",
    "gains": {"edge": 0.7, "raw": 0.3},
    "bias": -0.25,
    "threshold": 0.5,
    "circuits": ["edge_l1", "neuron_relu"],
}


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

    @property
    def edge_gain_float(self) -> float:
        return self.edge_gain_pct / 1000.0

    @property
    def raw_gain_float(self) -> float:
        return self.raw_gain_pct / 1000.0

    @property
    def bias_float(self) -> float:
        return self.bias_pct / 1000.0

    @property
    def threshold_float(self) -> float:
        return self.threshold_pct / 1000.0


def _load_yaml_or_json(path: pathlib.Path) -> Dict[str, Any]:
    data: Dict[str, Any]
    text = path.read_text()
    if yaml is not None:  # pragma: no branch - normal path
        data = yaml.safe_load(text)  # type: ignore[assignment]
    else:
        data = json.loads(text)

    if not isinstance(data, dict):
        raise SandConfigError("Top-level configuration must be a mapping")
    return data


def _get_nested(mapping: Mapping[str, Any], key: str, default: Any = None) -> Any:
    if key in mapping and mapping[key] is not None:
        return mapping[key]
    return default


def _thousandths(value: float) -> int:
    return int(round(value * 1000.0))


def _parse_scalar(value: Any, *, field: str) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    raise SandConfigError(f"Expected numeric value for '{field}', got {value!r}")


def resolve_neural_edge_params(config_path: pathlib.Path | None) -> NeuralEdgeParams:
    """Merge defaults with an optional YAML/JSON override."""
    merged = DEFAULT_NEURAL_EDGE_FLOATS.copy()
    if config_path:
        user_data = _load_yaml_or_json(config_path)
        if "neural_edge_slice" in user_data:
            user_data = user_data["neural_edge_slice"]
            if not isinstance(user_data, dict):
                raise SandConfigError("Field 'neural_edge_slice' must be a mapping")
        if "window" in user_data:
            merged_window = merged["window"].copy()
            merged_window.update(user_data.get("window") or {})
            merged["window"] = merged_window
        merged["pattern"] = _get_nested(user_data, "pattern", merged["pattern"])

        gains = merged["gains"].copy()
        if "gains" in user_data and isinstance(user_data["gains"], Mapping):
            gains.update(user_data["gains"])  # type: ignore[arg-type]
        merged["gains"] = gains
        for key in ("bias", "threshold"):
            if key in user_data and user_data[key] is not None:
                merged[key] = user_data[key]
        if "circuits" in user_data and user_data["circuits"] is not None:
            circuits_val = user_data["circuits"]
            if isinstance(circuits_val, (list, tuple)):
                merged["circuits"] = list(circuits_val)
            else:
                raise SandConfigError("Field 'circuits' must be a sequence")

        # Alternate integer thousandth overrides
        for key in ("edge_gain_pct", "raw_gain_pct", "bias_pct", "threshold_pct"):
            if key in user_data:
                merged[key] = user_data[key]

    window = merged["window"]
    try:
        window_w = int(window["width"])
        window_h = int(window["height"])
    except (KeyError, TypeError) as exc:
        raise SandConfigError("Window must define integer 'width' and 'height'") from exc

    pattern = str(merged["pattern"]).lower()
    if pattern not in PATTERN_TO_ID:
        raise SandConfigError(
            f"Unknown pattern '{pattern}'. Expected one of {sorted(PATTERN_TO_ID)}"
        )

    # Gains / bias / threshold can be provided as floats (0..1) or explicit thousandths.
    if "edge_gain_pct" in merged:
        edge_gain_pct = int(merged["edge_gain_pct"])
    else:
        edge_gain_pct = _thousandths(_parse_scalar(merged["gains"]["edge"], field="gains.edge"))

    if "raw_gain_pct" in merged:
        raw_gain_pct = int(merged["raw_gain_pct"])
    else:
        raw_gain_pct = _thousandths(_parse_scalar(merged["gains"]["raw"], field="gains.raw"))

    if "bias_pct" in merged:
        bias_pct = int(merged["bias_pct"])
    else:
        bias_pct = _thousandths(_parse_scalar(merged["bias"], field="bias"))

    if "threshold_pct" in merged:
        threshold_pct = int(merged["threshold_pct"])
    else:
        threshold_pct = _thousandths(_parse_scalar(merged["threshold"], field="threshold"))

    circuits = list(merged["circuits"])
    for circuit in circuits:
        if circuit not in CIRCUIT_LIBRARY:
            raise SandConfigError(
                f"Unknown circuit '{circuit}'. Available: {sorted(CIRCUIT_LIBRARY)}"
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
    """Generate the include header consumed by the testbench."""
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
    """Return the union of library sources needed for the requested circuits."""
    seen: set[pathlib.Path] = set()
    resolved: List[pathlib.Path] = []
    for name in params.circuits:
        entry = CIRCUIT_LIBRARY[name]
        source = entry["source"]
        if source not in seen:
            seen.add(source)
            resolved.append(source)
    return resolved
