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
    "neighbor_mix": {
        "source": pathlib.Path("rtl/circuits/sand_circuit_neighbor_mix.v"),
        "module": "sand_circuit_neighbor_mix",
        "description": "3D neighbor blend with programmable gains",
    },
    "activation_softsign": {
        "source": pathlib.Path("rtl/circuits/sand_circuit_activation_softsign.v"),
        "module": "sand_circuit_activation_softsign",
        "description": "Soft-saturating activation using the softsign curve",
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


ACTIVATION_PATTERN_TO_ID = {
    "core": 0,
    "ripple": 1,
    "layered": 2,
    "noise": 3,
}

DEFAULT_NEURAL_ACTIVATION = {
    "window": {"width": 6, "height": 6, "depth": 3},
    "pattern": "ripple",
    "iterations": 4,
    "aggregator": {
        "self": 0.55,
        "planar": 0.35,
        "vertical": 0.25,
        "bias": -0.12,
    },
    "feedback": {
        "gain": 0.4,
        "damp": 0.1,
    },
    "learning": {
        "rate": 0.12,
        "target": 0.35,
    },
    "readout": {
        "edge": 0.6,
        "raw": 0.4,
        "bias": -0.1,
        "threshold": 0.3,
    },
    "circuits": ["neighbor_mix", "activation_softsign", "neuron_relu"],
}


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


@dataclass
class ActivationFieldParams:
    window_w: int
    window_h: int
    window_d: int
    pattern: str
    pattern_id: int
    iterations: int
    self_gain_pct: int
    planar_gain_pct: int
    vertical_gain_pct: int
    bias_pct: int
    feedback_pct: int
    damp_pct: int
    learning_pct: int
    target_pct: int
    read_edge_pct: int
    read_raw_pct: int
    read_bias_pct: int
    read_threshold_pct: int
    circuits: Sequence[str]

    def override(
        self,
        *,
        window_w: int | None = None,
        window_h: int | None = None,
        window_d: int | None = None,
        pattern: str | None = None,
        iterations: int | None = None,
        self_gain_pct: int | None = None,
        planar_gain_pct: int | None = None,
        vertical_gain_pct: int | None = None,
        bias_pct: int | None = None,
        feedback_pct: int | None = None,
        damp_pct: int | None = None,
        learning_pct: int | None = None,
        target_pct: int | None = None,
        read_edge_pct: int | None = None,
        read_raw_pct: int | None = None,
        read_bias_pct: int | None = None,
        read_threshold_pct: int | None = None,
    ) -> "ActivationFieldParams":
        """Return a copy with selected fields overridden."""
        return ActivationFieldParams(
            window_w=window_w if window_w is not None else self.window_w,
            window_h=window_h if window_h is not None else self.window_h,
            window_d=window_d if window_d is not None else self.window_d,
            pattern=pattern if pattern is not None else self.pattern,
            pattern_id=ACTIVATION_PATTERN_TO_ID[pattern]
            if pattern is not None
            else self.pattern_id,
            iterations=iterations if iterations is not None else self.iterations,
            self_gain_pct=self_gain_pct if self_gain_pct is not None else self.self_gain_pct,
            planar_gain_pct=planar_gain_pct if planar_gain_pct is not None else self.planar_gain_pct,
            vertical_gain_pct=vertical_gain_pct if vertical_gain_pct is not None else self.vertical_gain_pct,
            bias_pct=bias_pct if bias_pct is not None else self.bias_pct,
            feedback_pct=feedback_pct if feedback_pct is not None else self.feedback_pct,
            damp_pct=damp_pct if damp_pct is not None else self.damp_pct,
            learning_pct=learning_pct if learning_pct is not None else self.learning_pct,
            target_pct=target_pct if target_pct is not None else self.target_pct,
            read_edge_pct=read_edge_pct if read_edge_pct is not None else self.read_edge_pct,
            read_raw_pct=read_raw_pct if read_raw_pct is not None else self.read_raw_pct,
            read_bias_pct=read_bias_pct if read_bias_pct is not None else self.read_bias_pct,
            read_threshold_pct=read_threshold_pct if read_threshold_pct is not None else self.read_threshold_pct,
            circuits=self.circuits,
        )


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


def resolve_activation_field_params(
    config_path: pathlib.Path | None,
) -> ActivationFieldParams:
    """
    Resolve configuration for the neural activation field behavioural example.
    """
    merged = json.loads(json.dumps(DEFAULT_NEURAL_ACTIVATION))
    if config_path:
        user_cfg = _load_yaml_or_json(config_path)
        if "neural_activation_field" in user_cfg:
            section = user_cfg["neural_activation_field"]
            if not isinstance(section, dict):
                raise SandConfigError("'neural_activation_field' must be a mapping")
        else:
            section = user_cfg

        if "window" in section:
            if not isinstance(section["window"], Mapping):
                raise SandConfigError("'window' must be a mapping")
            merged["window"].update(section["window"])  # type: ignore[arg-type]
        for key in ("pattern", "iterations"):
            if key in section and section[key] is not None:
                merged[key] = section[key]
        if "aggregator" in section:
            if not isinstance(section["aggregator"], Mapping):
                raise SandConfigError("'aggregator' must be a mapping")
            merged["aggregator"].update(section["aggregator"])  # type: ignore[arg-type]
        if "feedback" in section:
            if not isinstance(section["feedback"], Mapping):
                raise SandConfigError("'feedback' must be a mapping")
            merged["feedback"].update(section["feedback"])  # type: ignore[arg-type]
        if "learning" in section:
            if not isinstance(section["learning"], Mapping):
                raise SandConfigError("'learning' must be a mapping")
            merged["learning"].update(section["learning"])  # type: ignore[arg-type]
        if "readout" in section:
            if not isinstance(section["readout"], Mapping):
                raise SandConfigError("'readout' must be a mapping")
            merged["readout"].update(section["readout"])  # type: ignore[arg-type]
        if "circuits" in section and section["circuits"] is not None:
            if not isinstance(section["circuits"], (list, tuple)):
                raise SandConfigError("'circuits' must be a list")
            merged["circuits"] = list(section["circuits"])

        # Thousandth overrides
        for field in (
            "self_gain_pct",
            "planar_gain_pct",
            "vertical_gain_pct",
            "bias_pct",
            "feedback_pct",
            "damp_pct",
            "learning_pct",
            "target_pct",
            "read_edge_pct",
            "read_raw_pct",
            "read_bias_pct",
            "read_threshold_pct",
        ):
            if field in section and section[field] is not None:
                merged[field] = int(section[field])

    try:
        window_w = int(merged["window"]["width"])
        window_h = int(merged["window"]["height"])
        window_d = int(merged["window"]["depth"])
    except (KeyError, TypeError, ValueError) as exc:
        raise SandConfigError("'window' must define integer width/height/depth") from exc

    pattern = str(merged["pattern"]).lower()
    if pattern not in ACTIVATION_PATTERN_TO_ID:
        raise SandConfigError(
            f"Unknown pattern '{pattern}'. "
            f"Options: {', '.join(sorted(ACTIVATION_PATTERN_TO_ID))}"
        )

    iterations = int(merged.get("iterations", 1))
    if iterations < 1:
        raise SandConfigError("'iterations' must be >= 1")

    if "self_gain_pct" in merged:
        self_gain_pct = int(merged["self_gain_pct"])
    else:
        self_gain_pct = _thousandths(
            _as_float(merged["aggregator"]["self"], field="aggregator.self")
        )

    if "planar_gain_pct" in merged:
        planar_gain_pct = int(merged["planar_gain_pct"])
    else:
        planar_gain_pct = _thousandths(
            _as_float(merged["aggregator"]["planar"], field="aggregator.planar")
        )

    if "vertical_gain_pct" in merged:
        vertical_gain_pct = int(merged["vertical_gain_pct"])
    else:
        vertical_gain_pct = _thousandths(
            _as_float(merged["aggregator"]["vertical"], field="aggregator.vertical")
        )

    if "bias_pct" in merged:
        bias_pct = int(merged["bias_pct"])
    else:
        bias_pct = _thousandths(
            _as_float(merged["aggregator"]["bias"], field="aggregator.bias")
        )

    if "feedback_pct" in merged:
        feedback_pct = int(merged["feedback_pct"])
    else:
        feedback_pct = _thousandths(
            _as_float(merged["feedback"]["gain"], field="feedback.gain")
        )

    if "damp_pct" in merged:
        damp_pct = int(merged["damp_pct"])
    else:
        damp_pct = _thousandths(
            _as_float(merged["feedback"]["damp"], field="feedback.damp")
        )

    if "learning_pct" in merged:
        learning_pct = int(merged["learning_pct"])
    else:
        learning_pct = _thousandths(
            _as_float(merged["learning"]["rate"], field="learning.rate")
        )

    if "target_pct" in merged:
        target_pct = int(merged["target_pct"])
    else:
        target_pct = _thousandths(
            _as_float(merged["learning"]["target"], field="learning.target")
        )

    if "read_edge_pct" in merged:
        read_edge_pct = int(merged["read_edge_pct"])
    else:
        read_edge_pct = _thousandths(
            _as_float(merged["readout"]["edge"], field="readout.edge")
        )

    if "read_raw_pct" in merged:
        read_raw_pct = int(merged["read_raw_pct"])
    else:
        read_raw_pct = _thousandths(
            _as_float(merged["readout"]["raw"], field="readout.raw")
        )

    if "read_bias_pct" in merged:
        read_bias_pct = int(merged["read_bias_pct"])
    else:
        read_bias_pct = _thousandths(
            _as_float(merged["readout"]["bias"], field="readout.bias")
        )

    if "read_threshold_pct" in merged:
        read_threshold_pct = int(merged["read_threshold_pct"])
    else:
        read_threshold_pct = _thousandths(
            _as_float(merged["readout"]["threshold"], field="readout.threshold")
        )

    circuits = list(merged["circuits"])
    for name in circuits:
        if name not in CIRCUIT_LIBRARY:
            raise SandConfigError(
                f"Unknown circuit '{name}'. Known: {', '.join(sorted(CIRCUIT_LIBRARY))}"
            )

    return ActivationFieldParams(
        window_w=window_w,
        window_h=window_h,
        window_d=window_d,
        pattern=pattern,
        pattern_id=ACTIVATION_PATTERN_TO_ID[pattern],
        iterations=iterations,
        self_gain_pct=self_gain_pct,
        planar_gain_pct=planar_gain_pct,
        vertical_gain_pct=vertical_gain_pct,
        bias_pct=bias_pct,
        feedback_pct=feedback_pct,
        damp_pct=damp_pct,
        learning_pct=learning_pct,
        target_pct=target_pct,
        read_edge_pct=read_edge_pct,
        read_raw_pct=read_raw_pct,
        read_bias_pct=read_bias_pct,
        read_threshold_pct=read_threshold_pct,
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


def write_activation_field_header(
    params: ActivationFieldParams, output: pathlib.Path
) -> None:
    lines = [
        "// Auto-generated by sand_configurator.py",
        "`ifndef NEURAL_ACTIVATION_FIELD_CONFIG_VH",
        "`define NEURAL_ACTIVATION_FIELD_CONFIG_VH",
        f"localparam integer NAF_WINDOW_W_DEFAULT   = {params.window_w};",
        f"localparam integer NAF_WINDOW_H_DEFAULT   = {params.window_h};",
        f"localparam integer NAF_WINDOW_D_DEFAULT   = {params.window_d};",
        f"localparam integer NAF_PATTERN_ID_DEFAULT = {params.pattern_id};",
        f"localparam integer NAF_ITERATIONS_DEFAULT = {params.iterations};",
        f"localparam integer NAF_SELF_GAIN_PCT      = {params.self_gain_pct};",
        f"localparam integer NAF_PLANAR_GAIN_PCT    = {params.planar_gain_pct};",
        f"localparam integer NAF_VERTICAL_GAIN_PCT  = {params.vertical_gain_pct};",
        f"localparam integer NAF_BIAS_PCT           = {params.bias_pct};",
        f"localparam integer NAF_FEEDBACK_PCT       = {params.feedback_pct};",
        f"localparam integer NAF_DAMP_PCT           = {params.damp_pct};",
        f"localparam integer NAF_LEARNING_PCT       = {params.learning_pct};",
        f"localparam integer NAF_TARGET_PCT         = {params.target_pct};",
        f"localparam integer NAF_READ_EDGE_PCT      = {params.read_edge_pct};",
        f"localparam integer NAF_READ_RAW_PCT       = {params.read_raw_pct};",
        f"localparam integer NAF_READ_BIAS_PCT      = {params.read_bias_pct};",
        f"localparam integer NAF_READ_THRESH_PCT    = {params.read_threshold_pct};",
        "`endif  // NEURAL_ACTIVATION_FIELD_CONFIG_VH",
        "",
    ]
    output.write_text("\n".join(lines))


def required_sources(circuits: Sequence[str]) -> List[pathlib.Path]:
    """Return library sources needed by the requested circuits."""
    seen: set[pathlib.Path] = set()
    sources: List[pathlib.Path] = []
    for name in circuits:
        src = CIRCUIT_LIBRARY[name]["source"]
        if src not in seen:
            seen.add(src)
            sources.append(src)
    return sources
