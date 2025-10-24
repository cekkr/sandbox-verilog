"""
Utilities for compiling and running Sand Verilog simulations with Icarus.

This module centralises common plumbing so examples can focus on modelling
logic rather than subprocess orchestration.  It also doubles as a future
home for UART/serial transports by exposing a small abstraction layer that
can be extended later without rewriting the examples.
"""
from __future__ import annotations

from dataclasses import dataclass
import pathlib
import subprocess
from typing import Iterable, Mapping, Sequence


class SandToolError(RuntimeError):
    """Raised when a helper command fails."""


@dataclass
class IcarusBuildConfig:
    sources: Sequence[pathlib.Path]
    output: pathlib.Path
    include_dirs: Sequence[pathlib.Path] = ()
    defines: Mapping[str, str | None] | None = None
    top: str | None = None


def _ensure_list(values: Iterable[pathlib.Path]) -> list[str]:
    return [str(path) for path in values]


def compile_icarus(config: IcarusBuildConfig, cwd: pathlib.Path | None = None) -> pathlib.Path:
    """
    Invoke iverilog in IEEE-2012 mode and produce a VVP output binary.

    Args:
        config: build description (sources, output path, include dirs, defines).
        cwd: optional working directory for the compiler.
    Returns:
        Path to the generated VVP binary.
    Raises:
        SandToolError: if iverilog exits with a non-zero status.
    """
    cmd = ["iverilog", "-g2012", "-o", str(config.output)]

    for inc in config.include_dirs:
        cmd.extend(["-I", str(inc)])

    if config.defines:
        for key, value in config.defines.items():
            if value is None:
                cmd.append(f"-D{key}")
            else:
                cmd.append(f"-D{key}={value}")

    if config.top:
        cmd.extend(["-s", config.top])

    cmd.extend(_ensure_list(config.sources))

    try:
        subprocess.run(cmd, check=True, cwd=cwd)
    except subprocess.CalledProcessError as exc:
        raise SandToolError(f"iverilog failed with return code {exc.returncode}") from exc

    return config.output


def run_vvp(executable: pathlib.Path, plusargs: Mapping[str, str | int] | None = None,
            cwd: pathlib.Path | None = None) -> str:
    """
    Execute a compiled VVP simulation and capture stdout.

    Args:
        executable: compiled output from :func:`compile_icarus`.
        plusargs: optional mapping of plusargs (key -> value) pushed as +KEY=value.
        cwd: optional working directory for vvp.
    Returns:
        Captured stdout as a string. Stderr is inherited for visibility.
    Raises:
        SandToolError: if vvp exits with a non-zero status.
    """
    cmd = ["vvp", str(executable)]
    if plusargs:
        for key, value in plusargs.items():
            cmd.append(f"+{key}={value}")

    try:
        completed = subprocess.run(cmd, check=True, capture_output=True, text=True, cwd=cwd)
    except subprocess.CalledProcessError as exc:
        raise SandToolError(f"vvp failed with return code {exc.returncode}") from exc

    return completed.stdout


def q_to_float(value: int, frac_bits: int) -> float:
    """Convert a fixed-point Q number into floating point."""
    return float(value) / float(1 << frac_bits)
