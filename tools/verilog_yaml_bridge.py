"""
Bidirectional bridge between Verilog RTL sources and a structured YAML view.

The YAML side exposes a PyVerilog-derived AST (suitable for scripted edits) plus
lightweight summaries so humans can reason about module interfaces. Headers that
are primarily macro directives are represented as ordered statements for direct
manipulation.
"""
from __future__ import annotations

import argparse
import inspect
import re
import tempfile
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence


try:
    import yaml  # type: ignore
except ImportError as exc:  # pragma: no cover - PyYAML is mandatory
    raise SystemExit("PyYAML is required; install with `python3 -m pip install pyyaml`.") from exc

try:
    from pyverilog.ast_code_generator.codegen import ASTCodeGenerator
    from pyverilog.vparser import ast as vast
    from pyverilog.vparser.parser import ParseError, parse as parse_verilog
except ImportError as exc:  # pragma: no cover - PyVerilog is mandatory
    raise SystemExit(
        "PyVerilog is required; install with `python3 -m pip install pyverilog`."
    ) from exc


INCLUDE_PATTERN = r"`include"
RTL_SUFFIXES = (".v", ".sv")
HEADER_SUFFIXES = (".vh", ".svh")
YAML_VERSION = 1
FUNCTION_HEADER_RE = re.compile(
    r"(^\s*)function\s+([^;]*?)\s+([A-Za-z_][\w$]*)\s*;",
    re.IGNORECASE | re.MULTILINE,
)
INT_PORT_RE = re.compile(
    r"(^\s*(?:input|output)\s+)integer(\s+)", re.MULTILINE
)
BLOCK_INTEGER_RE = re.compile(
    r"(^[ \t]{8,})integer\s+([^;]+);", re.MULTILINE
)
BLOCK_TYPED_DECL_RE = re.compile(
    r"(^[ \t]{8,})(?P<type>(?:reg|wire|logic)(?:\s+signed)?)"
    r"(?:\s+(?P<range>\[[^\]]+\]))?\s+(?P<names>[^;]+);",
    re.MULTILINE,
)
BLOCK_DECL_MARKER_RE = re.compile(
    r"(^\s*)/\*__BLOCK_DECL__ ([^*]+?;)\*/",
    re.MULTILINE,
)
GLOBAL_INTEGER_RE = re.compile(
    r"^[ \t]{0,4}integer\s+([^;]+);",
    re.MULTILINE,
)
REPLICATION_COUNT_RE = re.compile(
    r"(?P<prefix>\{\s*\{?\s*)(?P<count>(?:\([^{}]*\)|[^{}])+?)(?P<suffix>\s*\{)"
)
REPLICATION_CONST_RE = re.compile(
    r"""
    ^
    (?:
        \d+ |
        \d+'[bB][0-1_xzXZ]+ |
        \d+'[dD][0-9_xzXZ]+ |
        \d+'[hH][0-9a-fA-F_xzXZ]+ |
        \d+'[oO][0-7_xzXZ]+
    )
    $
    """,
    re.VERBOSE,
)
PAREN_SLICE_RE = re.compile(
    r"\((?P<expr>[-+~!]\s*[\w$]+)\)\s*(?P<slice>\[[^\]]+\])"
)


def load_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def save_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def extract_includes(text: str) -> List[str]:
    includes: List[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("`include"):
            try:
                target = stripped.split('"', 2)[1]
            except IndexError:
                continue
            includes.append(target)
    return includes


def is_module_file(path: Path) -> bool:
    return path.suffix.lower() in RTL_SUFFIXES


def is_header_file(path: Path) -> bool:
    return path.suffix.lower() in HEADER_SUFFIXES


# ------------------------------------------------------------------------------
# PyVerilog AST <> YAML conversion helpers
# ------------------------------------------------------------------------------

_CODEGEN = ASTCodeGenerator()
_SERIALIZE_SKIP_ATTRS = {"coord", "lineno"}


def _expr_to_str(node: Any) -> Optional[str]:
    if node is None:
        return None
    return _CODEGEN.visit(node)


def _get_init_params(cls: type[vast.Node]) -> List[str]:
    """Return constructor parameter names (excluding self)."""
    params: List[str] = []
    signature = inspect.signature(cls.__init__)  # type: ignore[attr-defined]
    for idx, (name, param) in enumerate(signature.parameters.items()):
        if idx == 0:
            continue  # skip self
        if param.kind in (inspect.Parameter.VAR_POSITIONAL, inspect.Parameter.VAR_KEYWORD):
            params.append(name)
        else:
            params.append(name)
    return params


def _compact_dict(mapping: Dict[str, Any]) -> Dict[str, Any]:
    """Drop entries whose value is None."""
    return {key: value for key, value in mapping.items() if value is not None}


def _fill_required_kwargs(cls: type[vast.Node], kwargs: Dict[str, Any]) -> None:
    """Ensure kwargs cover required constructor parameters, defaulting to None when omitted."""
    signature = inspect.signature(cls.__init__)  # type: ignore[attr-defined]
    for idx, (name, param) in enumerate(signature.parameters.items()):
        if idx == 0:
            continue  # skip self
        if param.kind in (inspect.Parameter.VAR_POSITIONAL, inspect.Parameter.VAR_KEYWORD):
            continue
        if name in kwargs:
            continue
        if param.default is inspect._empty:
            kwargs[name] = None


def ast_to_dict(node: Any) -> Any:
    """Serialise a PyVerilog AST node (or nested structure) into pure Python types."""
    if node is None:
        return None
    if isinstance(node, (str, int, float, bool)):
        return node
    if isinstance(node, list):
        return [ast_to_dict(item) for item in node]
    if isinstance(node, tuple):
        return {"_tuple": [ast_to_dict(item) for item in node]}
    if isinstance(node, vast.Node):
        cls = node.__class__
        attrs = {
            name: value
            for name, value in vars(node).items()
            if name not in _SERIALIZE_SKIP_ATTRS
        }
        record: Dict[str, Any] = {"_type": cls.__name__}
        init_params = _get_init_params(cls)
        for name in init_params:
            if name not in attrs:
                continue
            serialised = ast_to_dict(attrs.pop(name))
            if serialised is None:
                continue
            record[name] = serialised
        for name in list(attrs.keys()):
            serialised = ast_to_dict(attrs[name])
            if serialised is None:
                continue
            record[name] = serialised
        return record
    # Fallback: convert to string
    return str(node)


def dict_to_ast(data: Any) -> Any:
    """Recreate PyVerilog AST nodes from the serialised form."""
    if data is None or isinstance(data, (str, int, float, bool)):
        return data
    if isinstance(data, list):
        return [dict_to_ast(item) for item in data]
    if isinstance(data, dict):
        if "_tuple" in data:
            return tuple(dict_to_ast(item) for item in data["_tuple"])
        if "_type" in data:
            type_name: str = data["_type"]
            if not hasattr(vast, type_name):
                raise ValueError(f"Unknown AST node type: {type_name}")
            cls = getattr(vast, type_name)
            # Backwards compatibility: legacy format with args/extras buckets.
            args_bucket = data.get("args")
            extras_bucket = data.get("extras")
            legacy_like = False
            if isinstance(args_bucket, dict):
                legacy_like = any(not key.startswith("_") for key in args_bucket.keys())
            if not legacy_like and isinstance(extras_bucket, dict):
                legacy_like = any(not key.startswith("_") for key in extras_bucket.keys())
            if legacy_like:
                args_data = args_bucket or {}
                init_kwargs = {
                    name: dict_to_ast(value)
                    for name, value in args_data.items()
                    if name not in _SERIALIZE_SKIP_ATTRS
                }
                _fill_required_kwargs(cls, init_kwargs)
                node = cls(**init_kwargs)
                extras = extras_bucket or {}
                for name, value in extras.items():
                    if name in _SERIALIZE_SKIP_ATTRS:
                        continue
                    setattr(node, name, dict_to_ast(value))
                return node
            init_params = set(_get_init_params(cls))
            init_kwargs: Dict[str, Any] = {}
            extras: Dict[str, Any] = {}
            for name, value in data.items():
                if name in ("_type",):
                    continue
                if name in _SERIALIZE_SKIP_ATTRS:
                    continue
                resolved = dict_to_ast(value)
                if name in init_params:
                    init_kwargs[name] = resolved
                else:
                    extras[name] = resolved
            _fill_required_kwargs(cls, init_kwargs)
            node = cls(**init_kwargs)
            for name, value in extras.items():
                setattr(node, name, value)
            return node
        return {key: dict_to_ast(value) for key, value in data.items()}
    raise TypeError(f"Unsupported data type in AST reconstruction: {type(data)}")


def _is_constant_replication_count(expr: str) -> bool:
    stripped = expr.strip().replace(" ", "")
    if not stripped:
        return False
    if stripped.isdigit():
        return True
    return bool(REPLICATION_CONST_RE.fullmatch(stripped))


def _sanitize_replication_counts(text: str, hints: Dict[str, Any]) -> str:
    replacements: List[str] = hints.setdefault("replication_counts", [])

    def repl(match: re.Match[str]) -> str:
        prefix = match.group("prefix")
        count_expr = match.group("count")
        suffix = match.group("suffix")
        if _is_constant_replication_count(count_expr):
            return match.group(0)
        idx = len(replacements)
        replacements.append(count_expr)
        marker = f"/*__REPL_{idx}__*/1"
        return f"{prefix}{marker}{suffix}"

    return REPLICATION_COUNT_RE.sub(repl, text)


def _sanitize_parenthesised_slices(text: str, hints: Dict[str, Any]) -> str:
    slices: List[str] = hints.setdefault("paren_slices", [])

    def repl(match: re.Match[str]) -> str:
        expr = match.group("expr")
        slice_part = match.group("slice")
        idx = len(slices)
        slices.append(slice_part)
        return f"({expr})/*__PAREN_SLICE_{idx}__*/"

    return PAREN_SLICE_RE.sub(repl, text)


def sanitize_for_parse(text: str) -> tuple[str, Dict[str, Any]]:
    """Relax SystemVerilog-only constructs so PyVerilog can parse the source."""
    hints: Dict[str, Any] = {"functions": {}, "replication_counts": [], "paren_slices": []}
    global_integers: set[str] = set()
    override_macros = "`define SATURATE 0\n`define ROUND_MUL 0\n"
    sanitized_text = override_macros + text
    math_override = (
        "`undef SAT_ADD\n"
        "`undef SAT_SUB\n"
        "`undef FP_ADD\n"
        "`undef FP_SUB\n"
        "`define SAT_ADD(a,b,DATA_W) ((a)+(b))\n"
        "`define SAT_SUB(a,b,DATA_W) ((a)-(b))\n"
        "`define FP_ADD(a,b,DATA_W) ((a)+(b))\n"
        "`define FP_SUB(a,b,DATA_W) ((a)-(b))\n"
    )
    sanitized_text = sanitized_text.replace(
        '`include "sand_math.vh"',
        '`include "sand_math.vh"\n' + math_override,
        1,
    )
    # Recompute global integers from the original text to preserve naming.
    for match in GLOBAL_INTEGER_RE.finditer(text):
        for name in match.group(1).split(','):
            cleaned = name.strip()
            if cleaned:
                global_integers.add(cleaned)
    block_stub_decls: List[Dict[str, str]] = []

    def repl(match: re.Match[str]) -> str:
        indent = match.group(1)
        qualifiers_original = match.group(2)
        name = match.group(3)
        tokens = qualifiers_original.replace("\n", " ").split()
        automatic = False
        integer_return = False
        rebuilt: List[str] = []
        idx = 0
        signed_return = False
        while idx < len(tokens):
            token = tokens[idx]
            if token == "automatic":
                automatic = True
            elif token == "signed" and idx + 1 < len(tokens) and tokens[idx + 1].startswith("["):
                signed_return = True
            elif token == "integer":
                integer_return = True
                rebuilt.extend(["[31:0]", "/*__INT_RET__*/"])
            else:
                rebuilt.append(token)
            idx += 1
        sanitized = " ".join(rebuilt).strip()
        hints["functions"][name] = {
            "automatic": automatic,
            "integer_return": integer_return,
            "signed_return": signed_return,
        }
        qualifier_str = f"{sanitized} " if sanitized else ""
        return f"{indent}function {qualifier_str}{name};"

    sanitized_text = FUNCTION_HEADER_RE.sub(repl, sanitized_text)
    sanitized_text = INT_PORT_RE.sub(r"\1[31:0] /*__INT_PORT__*/\2", sanitized_text)
    def block_decl_repl(match: re.Match[str]) -> str:
        indent = match.group(1)
        decls = match.group(2)
        for name in decls.split(','):
            cleaned = name.strip()
            if cleaned and cleaned not in global_integers:
                block_stub_decls.append(
                    {"type": "integer", "range": "", "name": cleaned}
                )
        return f"{indent}/*__BLOCK_DECL__ integer {decls};*/"

    def block_typed_decl_repl(match: re.Match[str]) -> str:
        indent = match.group(1)
        decl_type = match.group("type")
        range_part = match.group("range") or ""
        names = match.group("names")
        for name in names.split(','):
            cleaned = name.strip()
            if cleaned:
                block_stub_decls.append(
                    {"type": decl_type, "range": range_part, "name": cleaned}
                )
        rendered_range = f" {range_part}" if range_part else ""
        return f"{indent}/*__BLOCK_DECL__ {decl_type}{rendered_range} {names.strip()};*/"

    sanitized_text = BLOCK_TYPED_DECL_RE.sub(block_typed_decl_repl, sanitized_text)
    sanitized_text = BLOCK_INTEGER_RE.sub(block_decl_repl, sanitized_text)
    if block_stub_decls:
        unique_meta: Dict[str, Dict[str, str]] = {}
        for decl in block_stub_decls:
            name = decl["name"]
            if name in unique_meta:
                continue
            unique_meta[name] = decl
        stub_lines = "\n".join(
            f"    {meta['type']}"
            f"{(' ' + meta['range']) if meta['range'] else ''}"
            f" {name} /*__BLOCK_STUB__*/;"
            for name, meta in sorted(unique_meta.items())
        )
        insert_block = "\n    // __BLOCK_DECL_STUBS__\n" + stub_lines + "\n"
        insert_idx = sanitized_text.find("always")
        if insert_idx == -1:
            insert_idx = sanitized_text.find("initial")
        if insert_idx != -1:
            sanitized_text = (
                sanitized_text[:insert_idx]
                + insert_block
                + sanitized_text[insert_idx:]
            )
        else:
            sanitized_text += insert_block
    sanitized_text = _sanitize_replication_counts(sanitized_text, hints)
    sanitized_text = _sanitize_parenthesised_slices(sanitized_text, hints)
    return sanitized_text, hints


def apply_parse_hints(text: str, hints: Dict[str, Any]) -> str:
    """Re-apply SystemVerilog qualifiers that were stripped for parsing."""
    restored_text = text
    functions_meta: Dict[str, Any] = hints.get("functions", {})

    if functions_meta:

        def restore(match: re.Match[str]) -> str:
            indent = match.group(1)
            qualifiers = match.group(2)
            name = match.group(3)
            meta = functions_meta.get(name)
            if not meta:
                return match.group(0)
            tokens = qualifiers.replace("\n", " ").split()
            rebuilt: List[str] = []
            idx = 0
            while idx < len(tokens):
                token = tokens[idx]
                if (
                    meta.get("integer_return")
                    and token.startswith("[")
                    and idx + 1 < len(tokens)
                    and tokens[idx + 1] == "/*__INT_RET__*/"
                ):
                    rebuilt.append("integer")
                    idx += 2
                    continue
                rebuilt.append(token)
                idx += 1
            if meta.get("signed_return") and not meta.get("integer_return"):
                inserted = False
                for pos, token in enumerate(rebuilt):
                    if token.startswith("["):
                        rebuilt.insert(pos, "signed")
                        inserted = True
                        break
                if not inserted:
                    rebuilt.insert(0, "signed")
            if meta.get("automatic") and (not rebuilt or rebuilt[0] != "automatic"):
                rebuilt.insert(0, "automatic")
            restored = " ".join(rebuilt).strip()
            qualifier_str = f"{restored} " if restored else ""
            return f"{indent}function {qualifier_str}{name};"

        restored_text = FUNCTION_HEADER_RE.sub(restore, restored_text)

    restored_text = re.sub(
        r"(^\s*(?:input|output)\s+)\[31:0\]\s*/\*__INT_PORT__\*/",
        r"\1integer",
        restored_text,
        flags=re.MULTILINE,
    )
    restored_text = BLOCK_DECL_MARKER_RE.sub(
        lambda m: f"{m.group(1)}{m.group(2)}",
        restored_text,
    )
    restored_text = re.sub(
        r"\n\s*// __BLOCK_DECL_STUBS__\n(?:\s*(?:integer|(?:reg|wire|logic)(?:\s+signed)?)"
        r"(?:\s+\[[^\]]+\])?\s+\w+\s*/\*__BLOCK_STUB__\*/;\n?)+",
        "\n",
        restored_text,
    )

    for idx, expr in enumerate(hints.get("replication_counts", []) or []):
        marker = f"/*__REPL_{idx}__*/1"
        restored_text = restored_text.replace(marker, expr)

    for idx, slice_part in enumerate(hints.get("paren_slices", []) or []):
        token = f")/*__PAREN_SLICE_{idx}__*/"
        restored_text = restored_text.replace(token, f"){slice_part}")

    return restored_text


def header_summary(source_text: str, rtl_root: Path, source: Path) -> Dict[str, Any]:
    """Parse just the module header to build a lightweight summary."""
    marker = ");\n"
    end_idx = source_text.find(marker)
    if end_idx == -1:
        return {}
    header_only = source_text[: end_idx + len(marker)] + "\nendmodule\n"
    sanitized_header, _ = sanitize_for_parse(header_only)
    with tempfile.NamedTemporaryFile("w", suffix=source.suffix, delete=False) as tmp:
        tmp.write(sanitized_header)
        tmp_path = Path(tmp.name)
    try:
        ast_root, _ = parse_verilog([str(tmp_path)], preprocess_include=[str(source.parent), str(rtl_root)])
    except Exception:
        return {}
    finally:
        tmp_path.unlink(missing_ok=True)
    return summarise_ast(ast_root)


# ------------------------------------------------------------------------------
# Header (macro) parsing helpers
# ------------------------------------------------------------------------------

@dataclass
class Statement:
    type: str
    text: Optional[str] = None
    name: Optional[str] = None
    value: Optional[str] = None
    body: Optional[List[str]] = None


def parse_header(text: str) -> List[Statement]:
    """Parse a macro-centric header into structured statements."""
    statements: List[Statement] = []
    lines = text.splitlines()
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()
        if not stripped:
            statements.append(Statement(type="blank"))
            idx += 1
            continue
        if stripped.startswith("//"):
            statements.append(Statement(type="comment", text=line))
            idx += 1
            continue
        if stripped.startswith("`define"):
            tokens = stripped.split(None, 2)
            name = tokens[1] if len(tokens) > 1 else ""
            remainder = tokens[2] if len(tokens) > 2 else ""
            body = [line[line.find("`define") + len("`define ") + len(name):].lstrip()]
            while body and body[-1].endswith("\\") and idx + 1 < len(lines):
                idx += 1
                body.append(lines[idx])
            statements.append(Statement(type="define", name=name, body=body))
            idx += 1
            continue
        if stripped.startswith("`include"):
            try:
                target = stripped.split('"', 2)[1]
            except IndexError:
                target = stripped[len("`include") :].strip()
            statements.append(Statement(type="include", value=target))
            idx += 1
            continue
        if stripped.startswith("`ifdef"):
            name = stripped.split(None, 1)[1] if " " in stripped else ""
            statements.append(Statement(type="ifdef", name=name))
            idx += 1
            continue
        if stripped.startswith("`ifndef"):
            name = stripped.split(None, 1)[1] if " " in stripped else ""
            statements.append(Statement(type="ifndef", name=name))
            idx += 1
            continue
        if stripped.startswith("`endif"):
            statements.append(Statement(type="endif"))
            idx += 1
            continue
        if stripped.startswith("`else"):
            statements.append(Statement(type="else"))
            idx += 1
            continue
        statements.append(Statement(type="code", text=line))
        idx += 1
    return statements


def render_header(statements: Sequence[Statement]) -> str:
    """Render structured header statements back into Verilog preprocessor text."""
    output_lines: List[str] = []
    for stmt in statements:
        if stmt.type == "blank":
            output_lines.append("")
        elif stmt.type == "comment":
            output_lines.append(stmt.text or "")
        elif stmt.type == "define":
            body = stmt.body or [""]
            head = body[0].rstrip("\\").strip()
            line = f"`define {stmt.name} {head}".rstrip()
            if body[0].endswith("\\"):
                output_lines.append(line + " \\")
                for continuation in body[1:]:
                    output_lines.append(continuation)
            else:
                output_lines.append(line)
                output_lines.extend(body[1:])
        elif stmt.type == "include":
            output_lines.append(f'`include "{stmt.value}"')
        elif stmt.type == "ifdef":
            output_lines.append(f"`ifdef {stmt.name}")
        elif stmt.type == "ifndef":
            output_lines.append(f"`ifndef {stmt.name}")
        elif stmt.type == "else":
            output_lines.append("`else")
        elif stmt.type == "endif":
            output_lines.append("`endif")
        else:
            output_lines.append(stmt.text or "")
    return "\n".join(output_lines) + "\n"


# ------------------------------------------------------------------------------
# Summary generation
# ------------------------------------------------------------------------------


def summarise_module(module: vast.ModuleDef) -> Dict[str, Any]:
    params: List[Dict[str, Any]] = []
    if module.paramlist is not None:
        for decl in module.paramlist.params:
            for param in decl.list:
                entry = _compact_dict(
                    {
                        "name": param.name,
                        "value": _expr_to_str(param.value),
                        "signed": bool(param.signed),
                    }
                )
                params.append(entry)
    ports: List[Dict[str, Any]] = []
    if module.portlist is not None:
        for entry in module.portlist.ports:
            if isinstance(entry, vast.Ioport):
                direction = entry.first.__class__.__name__.lower()
                name = getattr(entry.first, "name", None)
                width = _expr_to_str(entry.first.width)
                signed = bool(getattr(entry.first, "signed", False))
                kind = entry.second.__class__.__name__.lower() if entry.second else None
            elif isinstance(entry, vast.Port):
                direction = None
                name = getattr(entry, "name", None)
                width = _expr_to_str(getattr(entry, "width", None))
                signed = bool(getattr(entry, "signed", False))
                kind = None
            else:
                direction = entry.__class__.__name__.lower()
                name = getattr(entry, "name", None)
                width = None
                signed = False
                kind = None
            port = _compact_dict(
                {
                    "name": name,
                    "direction": direction,
                    "width": width,
                    "signed": signed,
                    "datatype": kind,
                }
            )
            ports.append(port)
    return {
        "name": module.name,
        "parameters": params,
        "ports": ports,
    }


def summarise_ast(ast_root: vast.Node) -> Dict[str, Any]:
    summary: Dict[str, Any] = {"modules": []}
    if not isinstance(ast_root, vast.Source):
        return summary
    if ast_root.description is None:
        return summary
    modules: List[Dict[str, Any]] = []
    for definition in getattr(ast_root.description, "definitions", []):
        if isinstance(definition, vast.ModuleDef):
            modules.append(summarise_module(definition))
    summary["modules"] = modules
    return summary


# ------------------------------------------------------------------------------
# Human-readable module extraction
# ------------------------------------------------------------------------------

def _width_to_str(width: Any) -> Optional[str]:
    if width is None:
        return None
    rendered = _expr_to_str(width)
    if rendered is None:
        return None
    return rendered.strip()


def _dimensions_to_str(dimensions: Any) -> Optional[List[str]]:
    if dimensions in (None, []):
        return None
    if isinstance(dimensions, (list, tuple)):
        parts: List[str] = []
        for item in dimensions:
            rendered = _expr_to_str(item)
            if rendered:
                parts.append(rendered.strip())
        return parts or None
    rendered = _expr_to_str(dimensions)
    if rendered is None:
        return None
    return [rendered.strip()]


def _normalise_named_list(section: Any) -> "OrderedDict[str, Dict[str, Any]]":
    normalised: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
    if not section:
        return normalised
    if isinstance(section, dict):
        for name, meta in section.items():
            data = dict(meta) if isinstance(meta, dict) else {"value": meta}
            normalised[name] = data
        return normalised
    if isinstance(section, list):
        for item in section:
            if not isinstance(item, dict):
                continue
            name = item.get("name")
            if not name:
                continue
            meta = dict(item)
            meta.pop("name", None)
            normalised[name] = meta
    return normalised


def _normalise_ports(section: Any) -> "OrderedDict[str, Dict[str, Any]]":
    if isinstance(section, dict):
        return OrderedDict(
            (name, dict(meta) if isinstance(meta, dict) else {"value": meta})
            for name, meta in section.items()
        )
    return _normalise_named_list(section)


def _ordered_dict_to_list(mapping: "OrderedDict[str, Dict[str, Any]]") -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    for name, meta in mapping.items():
        entry = {"name": name}
        entry.update(meta)
        compacted = _compact_dict(entry)
        if compacted:
            result.append(compacted)
    return result


def _merge_named_sections(existing: Any, generated: Any) -> "OrderedDict[str, Dict[str, Any]]":
    existing_map = _normalise_named_list(existing)
    generated_map = _normalise_named_list(generated)
    merged: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
    for name, data in generated_map.items():
        merged_entry = dict(data)
        existing_entry = existing_map.get(name, {})
        for key, value in existing_entry.items():
            if key not in merged_entry:
                merged_entry[key] = value
        merged[name] = _compact_dict(merged_entry)
    return merged


def _merge_ports(existing: Any, generated: Any) -> "OrderedDict[str, Dict[str, Any]]":
    existing_map = _normalise_ports(existing)
    generated_map = _normalise_ports(generated)
    merged: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
    for name, data in generated_map.items():
        merged_entry = dict(data)
        existing_entry = existing_map.get(name, {})
        for key, value in existing_entry.items():
            if key not in merged_entry:
                merged_entry[key] = value
        merged[name] = _compact_dict(merged_entry)
    return merged


def _stringify(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    rendered = _expr_to_str(value)
    if rendered is None:
        return None
    return rendered.strip()


def _update_port_entry(
    ports: "OrderedDict[str, Dict[str, Any]]",
    name: Optional[str],
    *,
    direction: Optional[str] = None,
    datatype: Optional[str] = None,
    width: Optional[str] = None,
    signed: Optional[bool] = None,
    dimensions: Optional[List[str]] = None,
) -> None:
    if not name:
        return
    entry = ports.setdefault(name, OrderedDict())
    if direction:
        entry["direction"] = direction
    if datatype and datatype != "wire":
        entry["type"] = datatype
    if width:
        entry["width"] = width
    if signed:
        entry["signed"] = True
    if dimensions:
        entry["dimensions"] = dimensions


def _statement_to_items(statement: Any) -> List[Any]:
    if statement is None:
        return []
    if isinstance(statement, vast.Block):
        items: List[Any] = []
        for sub in getattr(statement, "statements", []) or []:
            items.extend(_statement_to_items(sub))
        return items
    if isinstance(statement, vast.IfStatement):
        item: Dict[str, Any] = {"if": _expr_to_str(statement.cond)}
        then_body = _statement_to_items(statement.true_statement)
        if then_body:
            item["then"] = then_body
        else:
            item["then"] = []
        else_body = _statement_to_items(statement.false_statement)
        if else_body:
            item["else"] = else_body
        return [item]
    if isinstance(statement, vast.CaseStatement):
        item: Dict[str, Any] = {"case": _expr_to_str(statement.comp)}
        branches: "OrderedDict[str, List[Any]]" = OrderedDict()
        default_body: List[Any] = []
        for case_item in statement.caselist:
            labels: List[str] = []
            cond_values = case_item.cond
            if cond_values is None:
                labels.append("default")
            else:
                if not isinstance(cond_values, (list, tuple)):
                    cond_iterable = [cond_values]
                else:
                    cond_iterable = cond_values
                for cond in cond_iterable:
                    rendered = _expr_to_str(cond)
                    if rendered is not None:
                        labels.append(rendered)
            body = _statement_to_items(case_item.statement)
            if labels == ["default"]:
                default_body = body
            else:
                branches[", ".join(labels)] = body
        if branches:
            item["branches"] = branches
        if default_body:
            item["default"] = default_body
        return [item]
    rendered = _expr_to_str(statement)
    if rendered is None:
        return []
    return [rendered.strip()]


def _classify_always(sensitivity: List[str]) -> Optional[str]:
    if not sensitivity:
        return None
    if sensitivity == ["*"]:
        return "combinational"
    if any(entry.startswith("posedge") or entry.startswith("negedge") for entry in sensitivity):
        return "sequential"
    return None


def _humanise_module(module: vast.ModuleDef) -> Dict[str, Any]:
    parameters: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
    if module.paramlist is not None:
        for decl in module.paramlist.params:
            for param in getattr(decl, "list", []) or []:
                name = getattr(param, "name", None)
                if not name:
                    continue
                entry: Dict[str, Any] = OrderedDict()
                default = _expr_to_str(getattr(param, "value", None))
                if default is not None:
                    entry["default"] = default
                width = _width_to_str(getattr(param, "width", None))
                if width:
                    entry["width"] = width
                if bool(getattr(param, "signed", False)):
                    entry["signed"] = True
                parameters[name] = _compact_dict(entry)

    ports: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
    if module.portlist is not None:
        for port in module.portlist.ports or []:
            decl = getattr(port, "first", None)
            direction: Optional[str] = None
            width: Optional[str] = None
            signed: Optional[bool] = None
            dimensions: Optional[List[str]] = None
            name: Optional[str] = None
            datatype: Optional[str] = None
            if decl is not None:
                direction_map = {
                    "Input": "input",
                    "Output": "output",
                    "Inout": "inout",
                }
                direction = direction_map.get(decl.__class__.__name__)
                name = getattr(decl, "name", None)
                width = _width_to_str(getattr(decl, "width", None))
                signed = bool(getattr(decl, "signed", False))
                dimensions = _dimensions_to_str(getattr(decl, "dimensions", None))
            second = getattr(port, "second", None)
            if second is not None:
                if name is None:
                    name = getattr(second, "name", None)
                datatype = second.__class__.__name__.lower()
                if width is None:
                    width = _width_to_str(getattr(second, "width", None))
                if not signed:
                    signed = bool(getattr(second, "signed", False))
            if name is None and hasattr(port, "name"):
                name = getattr(port, "name")
            _update_port_entry(
                ports,
                name,
                direction=direction,
                datatype=datatype,
                width=width,
                signed=signed,
                dimensions=dimensions,
            )

    signals: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
    constants: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()

    for item in module.items or []:
        if isinstance(item, vast.Decl):
            for decl in item.list or []:
                if isinstance(decl, (vast.Input, vast.Output, vast.Inout)):
                    direction_map = {
                        "Input": "input",
                        "Output": "output",
                        "Inout": "inout",
                    }
                    direction = direction_map.get(decl.__class__.__name__)
                    _update_port_entry(
                        ports,
                        getattr(decl, "name", None),
                        direction=direction,
                        width=_width_to_str(getattr(decl, "width", None)),
                        signed=bool(getattr(decl, "signed", False)),
                        dimensions=_dimensions_to_str(getattr(decl, "dimensions", None)),
                    )
                    continue
                name = getattr(decl, "name", None)
                if not name:
                    continue
                if isinstance(decl, vast.Reg):
                    if name in ports:
                        _update_port_entry(
                            ports,
                            name,
                            datatype="reg",
                            width=_width_to_str(getattr(decl, "width", None)),
                            signed=bool(getattr(decl, "signed", False)),
                            dimensions=_dimensions_to_str(getattr(decl, "dimensions", None)),
                        )
                    else:
                        entry = _compact_dict(
                            {
                                "kind": "reg",
                                "width": _width_to_str(getattr(decl, "width", None)),
                                "signed": True if bool(getattr(decl, "signed", False)) else None,
                                "dimensions": _dimensions_to_str(getattr(decl, "dimensions", None)),
                                "init": _stringify(getattr(decl, "value", None)),
                            }
                        )
                        if entry:
                            signals[name] = entry
                    continue
                if isinstance(decl, vast.Wire):
                    entry = _compact_dict(
                        {
                            "kind": "wire",
                            "width": _width_to_str(getattr(decl, "width", None)),
                            "signed": True if bool(getattr(decl, "signed", False)) else None,
                            "dimensions": _dimensions_to_str(getattr(decl, "dimensions", None)),
                            "init": _stringify(getattr(decl, "value", None)),
                        }
                    )
                    if entry:
                        signals[name] = entry
                    continue
                if isinstance(decl, vast.Integer):
                    entry = _compact_dict({"kind": "integer"})
                    if entry:
                        signals[name] = entry
                    continue
                if isinstance(decl, vast.Localparam):
                    entry = _compact_dict(
                        {
                            "value": _expr_to_str(getattr(decl, "value", None)),
                            "signed": True if bool(getattr(decl, "signed", False)) else None,
                        }
                    )
                    if entry:
                        constants[name] = entry
                    continue
                if isinstance(decl, vast.Parameter):
                    # Local parameter declared inside body.
                    entry = _compact_dict(
                        {
                            "value": _expr_to_str(getattr(decl, "value", None)),
                            "signed": True if bool(getattr(decl, "signed", False)) else None,
                        }
                    )
                    if entry:
                        constants[name] = entry

    assignments: List[Dict[str, Any]] = []
    always_blocks: List[Dict[str, Any]] = []
    instances: List[Dict[str, Any]] = []

    for item in module.items or []:
        if isinstance(item, vast.Assign):
            entry = _compact_dict(
                {
                    "out": _expr_to_str(getattr(item, "left", None)),
                    "value": _expr_to_str(getattr(item, "right", None)),
                }
            )
            if entry:
                assignments.append(entry)
        elif isinstance(item, vast.Always):
            sensitivity: List[str] = []
            sens_list = getattr(item, "sens_list", None)
            if isinstance(sens_list, vast.SensList):
                for sens in sens_list.list or []:
                    if sens.type == "all":
                        sensitivity.append("*")
                    elif sens.type:
                        rendered = _expr_to_str(getattr(sens, "sig", None))
                        if rendered:
                            sensitivity.append(f"{sens.type} {rendered}")
                    else:
                        rendered = _expr_to_str(getattr(sens, "sig", None))
                        if rendered:
                            sensitivity.append(rendered)
            body = _statement_to_items(getattr(item, "statement", None))
            entry = _compact_dict(
                {
                    "on": sensitivity or None,
                    "type": _classify_always(sensitivity),
                    "body": body or None,
                }
            )
            if entry:
                always_blocks.append(entry)
        elif isinstance(item, vast.InstanceList):
            module_name = getattr(item, "module", None)
            for inst in getattr(item, "instances", []) or []:
                connections: Dict[str, Any] = OrderedDict()
                for conn in getattr(inst, "portlist", []) or []:
                    arg = getattr(conn, "argname", None)
                    rendered = _stringify(arg if arg is not None else getattr(conn, "arg", None))
                    if rendered is None:
                        continue
                    connections[conn.portname] = rendered
                parameters_map: Dict[str, Any] = OrderedDict()
                for param in getattr(inst, "parameterlist", []) or []:
                    rendered = _stringify(getattr(param, "argname", None))
                    if rendered is None:
                        rendered = _stringify(getattr(param, "arg", None))
                    if rendered is None:
                        continue
                    parameters_map[param.paramname] = rendered
                entry = _compact_dict(
                    {
                        "module": module_name,
                        "instance": getattr(inst, "name", None),
                        "parameters": parameters_map or None,
                        "connections": connections or None,
                    }
                )
                if entry:
                    instances.append(entry)

    interface: Dict[str, Any] = {}
    if parameters:
        interface["parameters"] = _ordered_dict_to_list(parameters)
    if ports:
        port_map: Dict[str, Dict[str, Any]] = {}
        for name, meta in ports.items():
            data = _compact_dict(dict(meta))
            if data:
                port_map[name] = data
        if port_map:
            interface["ports"] = port_map

    module_block: Dict[str, Any] = {
        "name": module.name,
        "interface": interface or None,
        "signals": _ordered_dict_to_list(signals) if signals else None,
        "constants": _ordered_dict_to_list(constants) if constants else None,
        "assignments": assignments or None,
        "always_blocks": always_blocks or None,
        "instances": instances or None,
    }
    return _compact_dict(module_block)


def humanise_ast(ast_root: vast.Node) -> List[Dict[str, Any]]:
    modules: List[Dict[str, Any]] = []
    if not isinstance(ast_root, vast.Source):
        return modules
    description = getattr(ast_root, "description", None)
    if description is None:
        return modules
    for definition in getattr(description, "definitions", []):
        if isinstance(definition, vast.ModuleDef):
            modules.append(_humanise_module(definition))
    return modules


def build_sand_module_record(
    modules: List[Dict[str, Any]],
    ast_summary: Dict[str, Any],
    includes: List[str],
    source: Path,
    rtl_root: Path,
    machine_rel: Path,
) -> Dict[str, Any]:
    if not modules:
        raise ValueError("No modules available to build sand_module record")
    primary = modules[0]
    original_rel = str(source.relative_to(rtl_root)).replace("\\", "/")
    record: Dict[str, Any] = {
        "version": YAML_VERSION,
        "kind": "sand_module",
        "module": primary.get("name"),
        "original_path": original_rel,
        "includes": includes,
        "interface": primary.get("interface"),
        "signals": primary.get("signals"),
        "constants": primary.get("constants"),
        "assignments": primary.get("assignments"),
        "always_blocks": primary.get("always_blocks"),
        "instances": primary.get("instances"),
        "implementation": {
            "machine_path": str(machine_rel).replace("\\", "/"),
            "kind": "verilog_module",
        },
        "summary": ast_summary,
    }
    if len(modules) > 1:
        record["modules"] = modules
    return _compact_dict(record)


def merge_sand_module(existing: Dict[str, Any], generated: Dict[str, Any]) -> Dict[str, Any]:
    if not existing:
        return generated
    merged: Dict[str, Any] = dict(generated)
    for key in ("tags", "behaviour", "notes", "summary"):
        if key in existing:
            merged[key] = existing[key]
    existing_includes = existing.get("includes", []) or []
    generated_includes = generated.get("includes", []) or []
    seen: set[str] = set()
    combined_includes: List[str] = []
    for value in generated_includes + existing_includes:
        if value in seen:
            continue
        seen.add(value)
        combined_includes.append(value)
    if combined_includes:
        merged["includes"] = combined_includes

    interface_existing = existing.get("interface")
    interface_generated = generated.get("interface")
    if interface_generated:
        interface: Dict[str, Any] = {}
        generated_params = interface_generated.get("parameters")
        if generated_params is not None:
            merged_params = _merge_named_sections(
                interface_existing.get("parameters") if interface_existing else None,
                generated_params,
            )
            params_list = _ordered_dict_to_list(merged_params)
            if params_list:
                interface["parameters"] = params_list
        elif interface_existing and interface_existing.get("parameters") is not None:
            interface["parameters"] = interface_existing.get("parameters")
        generated_ports = interface_generated.get("ports")
        if generated_ports is not None:
            merged_ports = _merge_ports(
                interface_existing.get("ports") if interface_existing else None,
                generated_ports,
            )
            if merged_ports:
                port_map: Dict[str, Dict[str, Any]] = {}
                for name, meta in merged_ports.items():
                    data = _compact_dict(dict(meta))
                    if data:
                        port_map[name] = data
                if port_map:
                    interface["ports"] = port_map
        elif interface_existing and interface_existing.get("ports") is not None:
            interface["ports"] = interface_existing.get("ports")
        if interface_existing:
            for key, value in interface_existing.items():
                if key in interface:
                    continue
                interface[key] = value
        if interface:
            merged["interface"] = interface
    elif interface_existing:
        merged["interface"] = interface_existing

    for key in ("signals", "constants"):
        generated_section = generated.get(key)
        if generated_section is None:
            if key in existing:
                merged[key] = existing[key]
            continue
        merged_section = _merge_named_sections(existing.get(key), generated_section)
        section_list = _ordered_dict_to_list(merged_section)
        if section_list:
            merged[key] = section_list

    for key in ("assignments", "always_blocks", "instances"):
        if not generated.get(key) and existing.get(key):
            merged[key] = existing[key]

    if "implementation" in existing:
        impl = dict(existing["implementation"])
        impl.update(generated.get("implementation", {}))
        merged["implementation"] = impl

    return merged


# ------------------------------------------------------------------------------
# Export / Restore paths
# ------------------------------------------------------------------------------


def export_module(source: Path, rtl_root: Path, yaml_root: Path) -> None:
    text = load_text(source)
    includes = extract_includes(text)
    sanitized_text, hints = sanitize_for_parse(text)
    with tempfile.NamedTemporaryFile("w", suffix=source.suffix, delete=False) as tmp:
        tmp.write(sanitized_text)
        tmp_path = Path(tmp.name)
    parse_args = {
        "preprocess_include": [str(source.parent), str(rtl_root)],
    }
    try:
        ast_root, _ = parse_verilog([str(tmp_path)], **parse_args)
    except ParseError as error:
        tmp_path.unlink(missing_ok=True)
        hint = str(error)
        if "before: \"[\"" in hint:
            hint += " — PyVerilog cannot parse certain SystemVerilog bit-slice constructs (e.g. variable replication counts) yet."
        record = {
            "version": YAML_VERSION,
            "kind": "verilog_module_fallback",
            "original_path": str(source.relative_to(rtl_root)).replace("\\", "/"),
            "includes": includes,
            "summary": header_summary(text, rtl_root, source),
            "parse_error": hint,
            "body_text": text,
        }
        relative_path = source.relative_to(rtl_root)
        yaml_path = (yaml_root / relative_path).with_suffix(".yaml")
        yaml_path.parent.mkdir(parents=True, exist_ok=True)
        save_text(yaml_path, yaml.safe_dump(record, sort_keys=False))
        # Mirror fallback record into machine tree when exporting human descriptors.
        if yaml_root.resolve() != rtl_root.resolve():
            machine_root = yaml_root / "machine"
            machine_yaml_path = (machine_root / relative_path).with_suffix(".yaml")
            machine_yaml_path.parent.mkdir(parents=True, exist_ok=True)
            save_text(machine_yaml_path, yaml.safe_dump(record, sort_keys=False))
        return
    else:
        tmp_path.unlink(missing_ok=True)
    relative_path = source.relative_to(rtl_root)
    yaml_path = (yaml_root / relative_path).with_suffix(".yaml")

    human_tree = yaml_root.resolve() != rtl_root.resolve()

    if human_tree:
        existing: Optional[Dict[str, Any]] = None
        if yaml_path.exists():
            try:
                existing = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
            except Exception:
                existing = None
    else:
        existing = None

    ast_summary = summarise_ast(ast_root)
    modules = humanise_ast(ast_root)
    machine_record = {
        "version": YAML_VERSION,
        "kind": "verilog_module",
        "original_path": str(relative_path).replace("\\", "/"),
        "includes": includes,
        "summary": ast_summary,
        "ast": ast_to_dict(ast_root),
        "parse_hints": hints,
    }
    machine_root = yaml_root if not human_tree else yaml_root / "machine"
    machine_yaml_path = (machine_root / relative_path).with_suffix(".yaml")
    machine_yaml_path.parent.mkdir(parents=True, exist_ok=True)
    save_text(machine_yaml_path, yaml.safe_dump(machine_record, sort_keys=False))

    if not human_tree:
        # Exporting the machine tree directly; the machine YAML is the target artefact.
        if machine_yaml_path != yaml_path:
            save_text(yaml_path, yaml.safe_dump(machine_record, sort_keys=False))
        return

    should_emit_human = False
    if existing and existing.get("kind") == "sand_module":
        should_emit_human = True
    elif "circuits" in relative_path.parts:
        should_emit_human = True

    if should_emit_human and modules:
        depth = max(len(relative_path.parts) - 1, 0)
        if depth > 0:
            ascender = Path(*([".."] * depth))
            machine_rel = ascender / "machine" / relative_path.with_suffix(".yaml")
        else:
            machine_rel = Path("machine") / relative_path.with_suffix(".yaml")
        record = build_sand_module_record(
            modules,
            ast_summary,
            includes,
            source,
            rtl_root,
            machine_rel,
        )
        if existing and existing.get("kind") == "sand_module":
            record = merge_sand_module(existing, record)
        yaml_path.parent.mkdir(parents=True, exist_ok=True)
        save_text(yaml_path, yaml.safe_dump(record, sort_keys=False))
        return

    yaml_path.parent.mkdir(parents=True, exist_ok=True)
    save_text(yaml_path, yaml.safe_dump(machine_record, sort_keys=False))


def export_header(source: Path, rtl_root: Path, yaml_root: Path) -> None:
    text = load_text(source)
    statements = parse_header(text)
    record = {
        "version": YAML_VERSION,
        "kind": "verilog_header",
        "original_path": str(source.relative_to(rtl_root)).replace("\\", "/"),
        "statements": [
            _compact_dict(
                {
                    "type": stmt.type,
                    "text": stmt.text,
                    "name": stmt.name,
                    "value": stmt.value,
                    "body": stmt.body,
                }
            )
            for stmt in statements
        ],
    }
    yaml_path = yaml_root / source.relative_to(rtl_root)
    yaml_path = yaml_path.with_suffix(".yaml")
    save_text(yaml_path, yaml.safe_dump(record, sort_keys=False))


def export_tree(rtl_root: Path, yaml_root: Path, exclude: Sequence[str]) -> None:
    rtl_root = rtl_root.resolve()
    yaml_root = yaml_root.resolve()
    excluded_paths = {rtl_root / item for item in exclude}
    sources: List[Path] = []
    for path in sorted(rtl_root.rglob("*")):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if any(str(resolved).startswith(str(excluded.resolve())) for excluded in excluded_paths):
            continue
        if path.suffix.lower() not in (*RTL_SUFFIXES, *HEADER_SUFFIXES):
            continue
        sources.append(path)
    for source in sources:
        if is_module_file(source):
            export_module(source, rtl_root, yaml_root)
        elif is_header_file(source):
            export_header(source, rtl_root, yaml_root)


def restore_module(record: Dict[str, Any], yaml_path: Path, rtl_root: Path) -> None:
    ast_dict = record["ast"]
    ast_root = dict_to_ast(ast_dict)
    verilog = _CODEGEN.visit(ast_root)
    verilog = apply_parse_hints(verilog, record.get("parse_hints", {}))
    includes = [f'`include "{item}"' for item in record.get("includes", [])]
    text = ""
    if includes:
        text += "\n".join(includes) + "\n\n"
    text += verilog
    original_rel = Path(record["original_path"])
    destination = rtl_root / original_rel
    save_text(destination, text)


def restore_module_fallback(record: Dict[str, Any], rtl_root: Path) -> None:
    original_rel = Path(record["original_path"])
    destination = rtl_root / original_rel
    body = record.get("body_text", "")
    save_text(destination, body)


def _resolve_machine_path(yaml_path: Path, implementation: Dict[str, Any]) -> Path:
    machine_rel = (
        implementation.get("ast_path")
        or implementation.get("machine_path")
        or implementation.get("verilog_path")
    )
    if not machine_rel:
        raise ValueError(f"{yaml_path} missing implementation.ast_path or implementation.machine_path")
    machine_path = (yaml_path.parent / machine_rel).resolve()
    if not machine_path.is_file():
        raise FileNotFoundError(f"Machine definition not found: {machine_path}")
    return machine_path


def _module_record_from_source(source: Path) -> Dict[str, Any]:
    text = load_text(source)
    includes = extract_includes(text)
    sanitized_text, hints = sanitize_for_parse(text)
    with tempfile.NamedTemporaryFile("w", suffix=source.suffix, delete=False) as tmp:
        tmp.write(sanitized_text)
        tmp_path = Path(tmp.name)
    include_dirs: List[str] = []
    parent = source.parent
    include_dirs.append(str(parent))
    ancestor = parent.parent
    if ancestor != parent:
        include_dirs.append(str(ancestor))
    try:
        ast_root, _ = parse_verilog([str(tmp_path)], preprocess_include=include_dirs)
    except ParseError as error:
        tmp_path.unlink(missing_ok=True)
        return {
            "version": YAML_VERSION,
            "kind": "verilog_module_fallback",
            "original_path": source.name,
            "includes": includes,
            "summary": header_summary(text, source.parent, source),
            "parse_error": str(error),
            "body_text": text,
        }
    else:
        tmp_path.unlink(missing_ok=True)
        return {
            "version": YAML_VERSION,
            "kind": "verilog_module",
            "original_path": source.name,
            "includes": includes,
            "summary": summarise_ast(ast_root),
            "ast": ast_to_dict(ast_root),
            "parse_hints": hints,
        }


def _header_record_from_source(source: Path) -> Dict[str, Any]:
    text = load_text(source)
    statements = parse_header(text)
    return {
        "version": YAML_VERSION,
        "kind": "verilog_header",
        "original_path": source.name,
        "statements": [
            _compact_dict(
                {
                    "type": stmt.type,
                    "text": stmt.text,
                    "name": stmt.name,
                    "value": stmt.value,
                    "body": stmt.body,
                }
            )
            for stmt in statements
        ],
    }


def _load_machine_record(machine_path: Path) -> Dict[str, Any]:
    suffix = machine_path.suffix.lower()
    if suffix in {".yaml", ".yml"}:
        return yaml.safe_load(machine_path.read_text(encoding="utf-8"))
    if suffix in RTL_SUFFIXES:
        return _module_record_from_source(machine_path)
    if suffix in HEADER_SUFFIXES:
        return _header_record_from_source(machine_path)
    raise ValueError(f"Unsupported machine artefact type for {machine_path}")


def restore_sand_module(record: Dict[str, Any], yaml_path: Path, rtl_root: Path) -> None:
    implementation = record.get("implementation", {})
    machine_path = _resolve_machine_path(yaml_path, implementation)
    machine_record = _load_machine_record(machine_path)
    kind = machine_record.get("kind")
    if kind not in {"verilog_module", "verilog_module_machine", "verilog_module_fallback"}:
        raise ValueError(f"{machine_path} has unsupported module kind: {kind}")
    merged: Dict[str, Any] = {
        "version": machine_record.get("version", record.get("version", YAML_VERSION)),
        "kind": "verilog_module",
        "original_path": record.get(
            "original_path", machine_record.get("original_path")
        ),
        "includes": record.get("includes", machine_record.get("includes", [])),
        "summary": record.get("summary", machine_record.get("summary")),
    }
    if kind in {"verilog_module", "verilog_module_machine"}:
        merged["ast"] = machine_record.get("ast")
        merged["parse_hints"] = machine_record.get("parse_hints", {})
        if merged["ast"] is None:
            raise ValueError(f"{machine_path} does not supply an AST")
        restore_module(merged, yaml_path, rtl_root)
    else:
        fallback_record = {
            **merged,
            "kind": "verilog_module_fallback",
            "body_text": machine_record.get("body_text", ""),
            "parse_error": machine_record.get("parse_error"),
        }
        restore_module_fallback(fallback_record, rtl_root)


def restore_sand_header(record: Dict[str, Any], yaml_path: Path, rtl_root: Path) -> None:
    implementation = record.get("implementation", {})
    machine_path = _resolve_machine_path(yaml_path, implementation)
    machine_record = _load_machine_record(machine_path)
    if machine_record.get("kind") != "verilog_header":
        raise ValueError(f"{machine_path} expected verilog_header, found {machine_record.get('kind')}")
    restore_header(machine_record, rtl_root)


def restore_header(record: Dict[str, Any], rtl_root: Path) -> None:
    statements = [
        Statement(
            type=stmt.get("type"),
            text=stmt.get("text"),
            name=stmt.get("name"),
            value=stmt.get("value"),
            body=stmt.get("body"),
        )
        for stmt in record.get("statements", [])
    ]
    text = render_header(statements)
    destination = rtl_root / Path(record["original_path"])
    save_text(destination, text)


def restore_tree(yaml_root: Path, rtl_root: Path) -> None:
    yaml_root = yaml_root.resolve()
    rtl_root = rtl_root.resolve()
    machine_root = yaml_root / "machine"
    for yaml_path in sorted(yaml_root.rglob("*.yaml")):
        try:
            yaml_path.relative_to(machine_root)
        except ValueError:
            pass
        else:
            continue
        record = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
        kind = record.get("kind")
        if kind == "verilog_module":
            restore_module(record, yaml_path, rtl_root)
        elif kind == "verilog_module_fallback":
            restore_module_fallback(record, rtl_root)
        elif kind == "verilog_header":
            restore_header(record, rtl_root)
        elif kind == "sand_module":
            restore_sand_module(record, yaml_path, rtl_root)
        elif kind == "sand_header":
            restore_sand_header(record, yaml_path, rtl_root)
        elif kind == "verilog_module_machine":
            continue
        else:
            raise ValueError(f"{yaml_path} has unsupported kind: {kind}")


# ------------------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------------------


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Mirror Verilog RTL into structured YAML and back.")
    sub = parser.add_subparsers(dest="command", required=True)

    export_cmd = sub.add_parser("export", help="Convert Verilog RTL into YAML mirrors.")
    export_cmd.add_argument("--rtl-root", type=Path, default=Path("rtl"), help="Source RTL root directory.")
    export_cmd.add_argument("--yaml-root", type=Path, default=Path("rtl.yaml"), help="Destination YAML root directory.")
    export_cmd.add_argument(
        "--exclude",
        type=str,
        nargs="*",
        default=["legacy"],
        help="Subdirectories under rtl-root to skip.",
    )

    restore_cmd = sub.add_parser("restore", help="Regenerate Verilog RTL from YAML mirrors.")
    restore_cmd.add_argument("--yaml-root", type=Path, default=Path("rtl.yaml"), help="YAML source directory.")
    restore_cmd.add_argument("--rtl-root", type=Path, default=Path("rtl"), help="Destination RTL root directory.")

    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> None:
    args = parse_args(argv)
    if args.command == "export":
        export_tree(args.rtl_root, args.yaml_root, args.exclude)
    elif args.command == "restore":
        restore_tree(args.yaml_root, args.rtl_root)
    else:  # pragma: no cover - argparse enforces choices
        raise SystemExit(f"Unknown command: {args.command}")


if __name__ == "__main__":  # pragma: no cover
    main()
