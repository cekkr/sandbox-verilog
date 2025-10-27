"""
Dynamic Verilog configuration utilities for the Sand project.

This module introduces a feature/type registry that mimics the flexibility of
the Linux kernel configurator: users describe their target (developer profile,
FPGA budget, desired units) in YAML/JSON and the configurator stitches together
the required Verilog sources, build defines, and helper headers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import argparse
import json
import pathlib
from typing import Dict, Iterable, List, Mapping, MutableMapping, Optional, Sequence, Set

try:  # pragma: no cover - optional dependency
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore

from .sand_configurator import CIRCUIT_LIBRARY


class SandDynamicConfigError(RuntimeError):
    """Raised when dynamic configuration fails."""


@dataclass(frozen=True)
class ResourceFootprint:
    """Approximate resource usage for a feature on the target FPGA."""

    lut: Optional[int] = None
    ff: Optional[int] = None
    dsp: Optional[int] = None
    bram_kb: Optional[int] = None

    def fits(self, budget: "ResourceFootprint") -> bool:
        """Return True if this footprint fits within the given budget."""
        for field_name in ("lut", "ff", "dsp", "bram_kb"):
            need = getattr(self, field_name)
            have = getattr(budget, field_name)
            if need is not None and have is not None and need > have:
                return False
        return True

    def __add__(self, other: "ResourceFootprint") -> "ResourceFootprint":
        def combine(a: Optional[int], b: Optional[int]) -> Optional[int]:
            if a is None and b is None:
                return None
            return (a or 0) + (b or 0)

        return ResourceFootprint(
            lut=combine(self.lut, other.lut),
            ff=combine(self.ff, other.ff),
            dsp=combine(self.dsp, other.dsp),
            bram_kb=combine(self.bram_kb, other.bram_kb),
        )

    @classmethod
    def from_mapping(cls, data: Mapping[str, int | None]) -> "ResourceFootprint":
        """Construct a footprint from a mapping (e.g. parsed YAML section)."""
        def maybe_int(value: object) -> Optional[int]:
            if value is None:
                return None
            if isinstance(value, (int, float)):
                return int(value)
            return int(str(value))

        return cls(
            lut=maybe_int(data.get("lut")),
            ff=maybe_int(data.get("ff")),
            dsp=maybe_int(data.get("dsp")),
            bram_kb=maybe_int(data.get("bram_kb")),
        )


@dataclass(frozen=True)
class TypeSpec:
    """Describe a data type that Sand can be built around."""

    name: str
    kind: str  # "fixed" or "float"
    width: int
    description: str = ""
    frac_bits: Optional[int] = None
    exponent: Optional[int] = None
    mantissa: Optional[int] = None
    extra_macros: Mapping[str, str | int] = field(default_factory=dict)

    def to_defines(self) -> Dict[str, str]:
        """Return Verilog defines needed to realise this type."""
        defines: Dict[str, str] = {"DATA_W": str(self.width)}

        if self.kind == "fixed":
            frac = 0 if self.frac_bits is None else self.frac_bits
            defines["FRAC_W"] = str(frac)
            defines["SAND_TYPE_KIND"] = "fixed"
        elif self.kind == "float":
            defines["SAND_TYPE_KIND"] = "float"
            defines["SAND_TYPE_EXP_W"] = str(self.exponent or 0)
            defines["SAND_TYPE_MAN_W"] = str(self.mantissa or 0)
            defines.setdefault("FRAC_W", "0")
        else:  # pragma: no cover - guard against unsupported types
            raise SandDynamicConfigError(f"Unsupported type kind '{self.kind}'")

        for key, value in self.extra_macros.items():
            defines[str(key)] = str(value)

        return defines

    def as_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "kind": self.kind,
            "width": self.width,
            "description": self.description,
            "frac_bits": self.frac_bits,
            "exponent": self.exponent,
            "mantissa": self.mantissa,
            "extra_macros": dict(self.extra_macros),
        }


@dataclass(frozen=True)
class OperationSpec:
    """Describe a PE operation that can be surfaced to the project."""

    name: str
    opcode: str
    description: str
    requires: Sequence[str] = ()

    def as_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "opcode": self.opcode,
            "description": self.description,
            "requires": list(self.requires),
        }


@dataclass
class Feature:
    """Composable unit that can contribute sources, defines, and circuits."""

    name: str
    description: str
    tags: Set[str] = field(default_factory=set)
    depends: Sequence[str] = ()
    circuits: Sequence[str] = ()
    sources: Sequence[pathlib.Path] = ()
    defines: Mapping[str, str] = field(default_factory=dict)
    resource: ResourceFootprint = field(default_factory=ResourceFootprint)
    notes: Sequence[str] = ()

    def as_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "description": self.description,
            "tags": sorted(self.tags),
            "depends": list(self.depends),
            "circuits": list(self.circuits),
            "sources": [str(src) for src in self.sources],
            "defines": dict(self.defines),
            "resource": {
                "lut": self.resource.lut,
                "ff": self.resource.ff,
                "dsp": self.resource.dsp,
                "bram_kb": self.resource.bram_kb,
            },
            "notes": list(self.notes),
        }


@dataclass
class UnitSpec:
    """Describe a logical unit (module composition) requested by the user."""

    name: str
    circuits: Sequence[str]
    type_name: Optional[str] = None
    description: str = ""
    feature: Optional[str] = None
    lut_rom: Optional[pathlib.Path] = None

    def required_circuits(self) -> Set[str]:
        return set(self.circuits)

    def as_dict(self) -> Dict[str, object]:
        return {
            "name": self.name,
            "circuits": list(self.circuits),
            "type_name": self.type_name,
            "description": self.description,
            "feature": self.feature,
            "lut_rom": str(self.lut_rom) if self.lut_rom else None,
        }


@dataclass
class BuildPlan:
    """Resolved configuration that can feed synthesis or simulation."""

    defines: MutableMapping[str, str] = field(default_factory=dict)
    sources: List[pathlib.Path] = field(default_factory=list)
    include_dirs: List[pathlib.Path] = field(default_factory=list)
    circuits: List[str] = field(default_factory=list)
    operations: List[str] = field(default_factory=list)
    features: List[Feature] = field(default_factory=list)
    types: Dict[str, TypeSpec] = field(default_factory=dict)
    units: List[UnitSpec] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)

    def require_source(self, path: pathlib.Path) -> None:
        if path not in self.sources:
            self.sources.append(path)

    def require_circuit(self, circuit: str) -> None:
        if circuit not in self.circuits:
            self.circuits.append(circuit)

    def add_feature(self, feature: Feature) -> None:
        if feature not in self.features:
            self.features.append(feature)
            for name, value in feature.defines.items():
                self.defines.setdefault(name, value)
            for circuit in feature.circuits:
                self.require_circuit(circuit)
            for src in feature.sources:
                self.require_source(src)

    def as_manifest(self) -> Dict[str, object]:
        return {
            "defines": dict(self.defines),
            "sources": [str(src) for src in self.sources],
            "include_dirs": [str(inc) for inc in self.include_dirs],
            "circuits": list(self.circuits),
            "operations": list(self.operations),
            "features": [feature.as_dict() for feature in self.features],
            "types": {name: spec.as_dict() for name, spec in self.types.items()},
            "units": [unit.as_dict() for unit in self.units],
            "notes": list(self.notes),
        }


class FeatureRegistry:
    """Registry for reusable feature definitions."""

    def __init__(self) -> None:
        self._features: Dict[str, Feature] = {}

    def register(self, feature: Feature) -> None:
        if feature.name in self._features:
            raise SandDynamicConfigError(f"Feature '{feature.name}' already registered")
        self._features[feature.name] = feature

    def get(self, name: str) -> Feature:
        try:
            return self._features[name]
        except KeyError as exc:
            raise SandDynamicConfigError(f"Unknown feature '{name}'") from exc

    def all(self) -> Sequence[Feature]:
        return tuple(self._features.values())

    @classmethod
    def with_defaults(cls) -> "FeatureRegistry":
        """Populate a registry with built-in Sand features."""
        registry = cls()

        registry.register(
            Feature(
                name="core_base",
                description="Baseline Sand engine (top, scheduler, raster engine, job memory).",
                tags={"core", "fpga:baseline"},
                sources=[
                    pathlib.Path("rtl/sand_top.v"),
                    pathlib.Path("rtl/sand_scheduler_dynamic.v"),
                    pathlib.Path("rtl/sand_engine_raster.v"),
                    pathlib.Path("rtl/sand_jobmem2p.v"),
                    pathlib.Path("rtl/sand_pe.v"),
                    pathlib.Path("rtl/sand_defs.vh"),
                    pathlib.Path("rtl/sand_math.vh"),
                ],
                defines={"SAND_ENABLE_CORE": "1"},
                resource=ResourceFootprint(lut=18000, dsp=8, bram_kb=256),
            )
        )

        registry.register(
            Feature(
                name="feature_microcode",
                description="Expose microcode lookup table operations via OP_MICRO.",
                tags={"core", "microcode"},
                depends=("core_base",),
                defines={"SAND_ENABLE_MICROCODE": "1"},
                notes=("Requires CSR_MICRO_BASE to be accessible from host software.",),
            )
        )

        registry.register(
            Feature(
                name="feature_water_flux",
                description="Enable water flux and pressure solver opcodes.",
                tags={"fluid", "simulation"},
                depends=("core_base",),
                defines={
                    "SAND_ENABLE_WATER_FLUX": "1",
                    "SAND_ENABLE_PRESSURE_SOLVER": "1",
                },
                notes=("Consumes additional DSP slices when OP_WATER_FLUX is active.",),
                resource=ResourceFootprint(lut=2500, dsp=16),
            )
        )

        registry.register(
            Feature(
                name="unit_neural_edge",
                description="Neural edge slice unit composed of edge and ReLU circuits.",
                tags={"ml", "vision"},
                depends=("core_base",),
                circuits=("edge_l1", "neuron_relu"),
                defines={"SAND_ENABLE_NES_UNIT": "1"},
            )
        )

        registry.register(
            Feature(
                name="unit_activation_field",
                description="Neural activation field unit with neighbor mix and LUT core.",
                tags={"ml", "temporal"},
                depends=("core_base", "feature_microcode"),
                circuits=("neighbor_mix", "activation_micro_lut", "neuron_relu"),
                defines={"SAND_ENABLE_NAF_UNIT": "1"},
                notes=("Requires LUT init files generated by neural activation workflow.",),
            )
        )

        registry.register(
            Feature(
                name="feature_softsign",
                description="Expose softsign activation circuit as reusable unit.",
                tags={"ml"},
                depends=("core_base",),
                circuits=("activation_softsign",),
                defines={"SAND_ENABLE_SOFTSIGN": "1"},
            )
        )

        return registry


class TypeRegistry:
    """Registry of known Sand-compatible data types."""

    def __init__(self) -> None:
        self._types: Dict[str, TypeSpec] = {}

    def register(self, type_spec: TypeSpec) -> None:
        if type_spec.name in self._types:
            raise SandDynamicConfigError(f"Type '{type_spec.name}' already registered")
        self._types[type_spec.name] = type_spec

    def get(self, name: str) -> TypeSpec:
        try:
            return self._types[name]
        except KeyError as exc:
            raise SandDynamicConfigError(f"Unknown type '{name}'") from exc

    def ensure(self, type_spec: TypeSpec) -> None:
        """Register the type if it is not already present."""
        if type_spec.name not in self._types:
            self._types[type_spec.name] = type_spec

    def all(self) -> Sequence[TypeSpec]:
        return tuple(self._types.values())

    @classmethod
    def with_defaults(cls) -> "TypeRegistry":
        registry = cls()
        registry.register(
            TypeSpec(
                name="q8_8",
                kind="fixed",
                width=16,
                frac_bits=8,
                description="Signed Q8.8 fixed-point baseline.",
            )
        )
        registry.register(
            TypeSpec(
                name="q16_16",
                kind="fixed",
                width=32,
                frac_bits=16,
                description="Signed Q16.16 fixed-point for high precision accumulators.",
            )
        )
        registry.register(
            TypeSpec(
                name="bfloat16",
                kind="float",
                width=16,
                exponent=8,
                mantissa=7,
                description="bfloat16 (1 sign + 8 exp + 7 mantissa).",
            )
        )
        registry.register(
            TypeSpec(
                name="float16",
                kind="float",
                width=16,
                exponent=5,
                mantissa=10,
                description="IEEE-754 half precision.",
            )
        )
        registry.register(
            TypeSpec(
                name="float32",
                kind="float",
                width=32,
                exponent=8,
                mantissa=23,
                description="IEEE-754 single precision.",
            )
        )
        return registry


def default_operations() -> Dict[str, OperationSpec]:
    """Return builtin operations that can be surfaced to end users."""
    ops = [
        OperationSpec(
            name="edge_detect",
            opcode="OP_EDGE",
            description="4-neighbour |dx| + |dy| edge magnitude.",
            requires=("unit_neural_edge",),
        ),
        OperationSpec(
            name="microcode_lookup",
            opcode="OP_MICRO",
            description="Programmable 16-entry rule lookup.",
            requires=("feature_microcode",),
        ),
        OperationSpec(
            name="water_flux",
            opcode="OP_WATER_FLUX",
            description="Weighted water flux accumulator with overflow routing.",
            requires=("feature_water_flux",),
        ),
        OperationSpec(
            name="pressure_relax",
            opcode="OP_PRESSURE",
            description="Iterative pressure/exchange solver.",
            requires=("feature_water_flux",),
        ),
        OperationSpec(
            name="mix",
            opcode="OP_MIX",
            description="a*self + b*avg + c*sum + d mix operation.",
            requires=("core_base",),
        ),
        OperationSpec(
            name="softsign_activation",
            opcode="OP_MICRO",
            description="Softsign activation backed by activation_softsign circuit.",
            requires=("feature_softsign",),
        ),
    ]
    return {spec.name: spec for spec in ops}


def _load_yaml_or_json(path: pathlib.Path) -> Dict[str, object]:
    text = path.read_text()
    if yaml is not None:  # pragma: no branch
        config = yaml.safe_load(text)  # type: ignore[assignment]
    else:
        config = json.loads(text)
    if not isinstance(config, dict):
        raise SandDynamicConfigError("Configuration root must be a mapping")
    return config


class DynamicConfigurator:
    """Resolve a high-level Sand description into a concrete build plan."""

    def __init__(
        self,
        features: FeatureRegistry | None = None,
        types: TypeRegistry | None = None,
        operations: Mapping[str, OperationSpec] | None = None,
    ) -> None:
        self.features = features or FeatureRegistry.with_defaults()
        self.types = types or TypeRegistry.with_defaults()
        self.operations = dict(operations or default_operations())

    def list_features(self) -> Sequence[Feature]:
        return self.features.all()

    def list_types(self) -> Sequence[TypeSpec]:
        return self.types.all()

    def list_operations(self) -> Sequence[OperationSpec]:
        return tuple(self.operations.values())

    def parse_config(self, config: Mapping[str, object]) -> BuildPlan:
        """Build a plan from a parsed config mapping."""
        plan = BuildPlan()

        # Step 1: ensure type registry covers user supplied types.
        types_section = config.get("types")
        default_type_name = "q8_8"
        if isinstance(types_section, Mapping):
            default_type_name = str(types_section.get("default", default_type_name))

            custom_types = types_section.get("custom")
            if isinstance(custom_types, Sequence):
                for entry in custom_types:
                    if not isinstance(entry, Mapping):
                        raise SandDynamicConfigError("Each custom type must be a mapping")
                    type_spec = self._parse_type(entry)
                    self.types.ensure(type_spec)
                    plan.types.setdefault(type_spec.name, type_spec)

        try:
            default_type = self.types.get(default_type_name)
        except SandDynamicConfigError as exc:  # pragma: no cover - config error path
            raise SandDynamicConfigError(
                f"Default type '{default_type_name}' is not registered"
            ) from exc
        plan.types[default_type_name] = default_type
        plan.defines.update(default_type.to_defines())
        plan.notes.append(f"Default data type: {default_type.name}")

        # Step 2: capture resource constraints if any.
        constraints = ResourceFootprint()
        fpga_section = config.get("fpga")
        if isinstance(fpga_section, Mapping):
            res = fpga_section.get("resources")
            if isinstance(res, Mapping):
                constraints = ResourceFootprint.from_mapping(res)  # type: ignore[arg-type]

        # Step 3: units definitions.
        units_section = config.get("units")
        if isinstance(units_section, Sequence):
            for entry in units_section:
                if not isinstance(entry, Mapping):
                    raise SandDynamicConfigError("Each unit must be a mapping")
                plan.units.append(self._parse_unit(entry))

        # Step 4: figure out requested operations.
        ops_section = config.get("operations")
        requested_ops: Set[str] = set()
        if isinstance(ops_section, Mapping):
            include_ops = ops_section.get("include")
            if isinstance(include_ops, Sequence):
                for op_name in include_ops:
                    requested_ops.add(str(op_name))
        elif isinstance(ops_section, Sequence):
            for op_name in ops_section:
                requested_ops.add(str(op_name))

        # Always include operations bound to requested units.
        for unit in plan.units:
            if unit.feature:
                # operations bound to unit features are added below
                pass
        # Step 5: determine feature set (manual + dependencies).
        feature_section = config.get("features")
        enabled_features: Set[str] = set()
        disabled_features: Set[str] = set()
        auto_tags: Set[str] = set()
        if isinstance(feature_section, Mapping):
            enabled = feature_section.get("enable")
            if isinstance(enabled, Sequence):
                enabled_features.update(str(name) for name in enabled)
            disabled = feature_section.get("disable")
            if isinstance(disabled, Sequence):
                disabled_features.update(str(name) for name in disabled)
            tags_cfg = feature_section.get("tags")
            if isinstance(tags_cfg, Mapping):
                include_tags = tags_cfg.get("include")
                if isinstance(include_tags, Sequence):
                    auto_tags.update(str(tag) for tag in include_tags)
        elif isinstance(feature_section, Sequence):
            enabled_features.update(str(name) for name in feature_section)

        # Add features implied by operations.
        for op_name in requested_ops:
            spec = self.operations.get(op_name)
            if spec is None:
                raise SandDynamicConfigError(f"Unknown operation '{op_name}'")
            enabled_features.update(spec.requires)
        plan.operations.extend(sorted(requested_ops))

        # Add features implied by units.
        for unit in plan.units:
            if unit.feature:
                enabled_features.add(unit.feature)

        # Tag-based auto selection.
        if auto_tags:
            for feature in self.features.all():
                if feature.tags & auto_tags:
                    enabled_features.add(feature.name)

        # Remove disabled entries early.
        enabled_features.difference_update(disabled_features)

        resolved_features = self._resolve_features(enabled_features, disabled_features)

        # Confirm resources.
        total_usage = ResourceFootprint()
        for feature in resolved_features:
            total_usage += feature.resource
        if not total_usage.fits(constraints):
            raise SandDynamicConfigError(
                f"Requested features exceed FPGA budget {constraints} with footprint {total_usage}"
            )

        # Merge feature contributions into the plan.
        for feature in resolved_features:
            plan.add_feature(feature)

        # Add circuits required by units and map to source files.
        for unit in plan.units:
            for circuit in unit.circuits:
                plan.require_circuit(circuit)
            if unit.type_name:
                unit_type = self.types.get(unit.type_name)
                if unit_type.name not in plan.types:
                    plan.types[unit_type.name] = unit_type
                    plan.notes.append(f"Unit '{unit.name}' uses data type '{unit_type.name}'")

        for circuit in plan.circuits:
            if circuit not in CIRCUIT_LIBRARY:
                raise SandDynamicConfigError(
                    f"Unknown circuit '{circuit}'. Available: "
                    f"{', '.join(sorted(CIRCUIT_LIBRARY))}"
                )
            plan.require_source(CIRCUIT_LIBRARY[circuit]["source"])

        plan.notes.append("Use plan.defines as +define+ arguments for iverilog or your FPGA flow.")
        return plan

    def _parse_type(self, entry: Mapping[str, object]) -> TypeSpec:
        name = str(entry.get("name"))
        kind = str(entry.get("kind", "fixed"))
        width = int(entry.get("width", 16))
        description = str(entry.get("description", ""))
        frac_bits = entry.get("frac_bits")
        exponent = entry.get("exponent")
        mantissa = entry.get("mantissa")
        extra_macros = entry.get("extra_macros") or {}
        if not isinstance(extra_macros, Mapping):
            raise SandDynamicConfigError("'extra_macros' must be a mapping if provided")
        if kind == "fixed" and frac_bits is None:
            raise SandDynamicConfigError(f"Fixed-point type '{name}' must set 'frac_bits'")
        if kind == "float" and (exponent is None or mantissa is None):
            raise SandDynamicConfigError(f"Float type '{name}' must set 'exponent' and 'mantissa'")
        return TypeSpec(
            name=name,
            kind=kind,
            width=width,
            description=description,
            frac_bits=int(frac_bits) if frac_bits is not None else None,
            exponent=int(exponent) if exponent is not None else None,
            mantissa=int(mantissa) if mantissa is not None else None,
            extra_macros={str(k): str(v) for k, v in extra_macros.items()},
        )

    def _parse_unit(self, entry: Mapping[str, object]) -> UnitSpec:
        name = str(entry.get("name", "unit"))
        circuits = entry.get("circuits")
        if not isinstance(circuits, Sequence) or not circuits:
            raise SandDynamicConfigError(f"Unit '{name}' must provide a non-empty 'circuits' list")
        type_name = entry.get("type")
        description = str(entry.get("description", ""))
        feature = entry.get("feature")
        lut_rom = entry.get("lut_rom")
        lut_path = pathlib.Path(str(lut_rom)) if lut_rom else None
        if type_name is not None:
            type_name = str(type_name)
            self.types.get(type_name)  # validate early
        circuits_list = [str(circ) for circ in circuits]
        return UnitSpec(
            name=name,
            circuits=circuits_list,
            type_name=str(type_name) if type_name is not None else None,
            description=description,
            feature=str(feature) if feature is not None else None,
            lut_rom=lut_path,
        )

    def _resolve_features(
        self, enabled: Set[str], disabled: Set[str]
    ) -> List[Feature]:
        """Resolve feature dependencies and return the ordered feature list."""
        resolved: List[Feature] = []
        seen: Set[str] = set()

        def visit(name: str) -> None:
            if name in seen:
                return
            if name in disabled:
                raise SandDynamicConfigError(f"Feature '{name}' is disabled but required")
            feature = self.features.get(name)
            for dep in feature.depends:
                visit(dep)
            resolved.append(feature)
            seen.add(name)

        for name in enabled:
            visit(name)

        return resolved

    def render_type_header(self, plan: BuildPlan) -> str:
        """Render a Verilog header documenting the active types."""
        lines = [
            "// Auto-generated by sand_dynamic_configurator.py",
            "`ifndef SAND_DYNAMIC_TYPES_VH",
            "`define SAND_DYNAMIC_TYPES_VH",
            "",
        ]
        for name, spec in plan.types.items():
            lines.append(f"// Type '{name}': {spec.description or 'no description'}")
            defines = spec.to_defines()
            prefix = name.upper()
            for macro, value in defines.items():
                lines.append(f"`define SAND_TYPE_{prefix}_{macro} {value}")
            lines.append("")
        lines.append("`endif  // SAND_DYNAMIC_TYPES_VH")
        lines.append("")
        return "\n".join(lines)

    def write_outputs(
        self,
        plan: BuildPlan,
        output_dir: pathlib.Path,
        *,
        write_header: bool = True,
        write_manifest: bool = True,
    ) -> None:
        """Persist plan artefacts for downstream tools."""
        output_dir.mkdir(parents=True, exist_ok=True)
        if write_manifest:
            manifest_path = output_dir / "build_plan.json"
            manifest_path.write_text(json.dumps(plan.as_manifest(), indent=2))
        if write_header:
            header_path = output_dir / "sand_dynamic_types.vh"
            header_path.write_text(self.render_type_header(plan))


def _cmd_list(args: argparse.Namespace, configurator: DynamicConfigurator) -> int:
    section = args.section
    if section == "features":
        for feature in configurator.list_features():
            tag_str = f" ({', '.join(sorted(feature.tags))})" if feature.tags else ""
            print(f"{feature.name}{tag_str}: {feature.description}")
    elif section == "types":
        for spec in configurator.list_types():
            print(f"{spec.name} [{spec.kind} width={spec.width}]: {spec.description}")
    elif section == "operations":
        for spec in configurator.list_operations():
            req = f" requires: {', '.join(spec.requires)}" if spec.requires else ""
            print(f"{spec.name} -> {spec.opcode}:{req} | {spec.description}")
    else:
        raise SandDynamicConfigError(f"Unknown list section '{section}'")
    return 0


def _cmd_build(args: argparse.Namespace, configurator: DynamicConfigurator) -> int:
    config_path = pathlib.Path(args.config)
    config = _load_yaml_or_json(config_path)
    plan = configurator.parse_config(config)

    output_dir = pathlib.Path(args.output) if args.output else config_path.parent / "build"
    configurator.write_outputs(plan, output_dir)

    print(f"Wrote manifest to {output_dir / 'build_plan.json'}")
    print(f"Wrote type header to {output_dir / 'sand_dynamic_types.vh'}")
    print("Defines (pass as +define+NAME=value):")
    for name, value in plan.defines.items():
        print(f"  {name}={value}")

    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sand dynamic configurator")
    sub = parser.add_subparsers(dest="command", required=True)

    list_parser = sub.add_parser("list", help="List built-in features/types/operations")
    list_parser.add_argument(
        "section", choices=("features", "types", "operations"), help="Entity to list"
    )
    list_parser.set_defaults(func=_cmd_list)

    build_parser = sub.add_parser("build", help="Render a build plan from a config file")
    build_parser.add_argument("config", help="Path to YAML/JSON configuration")
    build_parser.add_argument(
        "--output", "-o", help="Directory to emit the manifest/header (defaults to ./build)"
    )
    build_parser.set_defaults(func=_cmd_build)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    configurator = DynamicConfigurator()
    return args.func(args, configurator)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
