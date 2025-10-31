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
BLOCK_DECL_MARKER_RE = re.compile(
    r"(^\s*)/\*__BLOCK_DECL__ (integer .*?;)\*/",
    re.MULTILINE,
)
GLOBAL_INTEGER_RE = re.compile(
    r"^[ \t]{0,4}integer\s+([^;]+);",
    re.MULTILINE,
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


def sanitize_for_parse(text: str) -> tuple[str, Dict[str, Any]]:
    """Relax SystemVerilog-only constructs so PyVerilog can parse the source."""
    hints: Dict[str, Any] = {"functions": {}}
    global_integers: set[str] = set()
    for match in GLOBAL_INTEGER_RE.finditer(text):
        for name in match.group(1).split(','):
            cleaned = name.strip()
            if cleaned:
                global_integers.add(cleaned)
    block_stub_names: List[str] = []

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

    sanitized_text = FUNCTION_HEADER_RE.sub(repl, text)
    sanitized_text = INT_PORT_RE.sub(r"\1[31:0] /*__INT_PORT__*/\2", sanitized_text)
    def block_decl_repl(match: re.Match[str]) -> str:
        indent = match.group(1)
        decls = match.group(2)
        for name in decls.split(','):
            cleaned = name.strip()
            if cleaned and cleaned not in global_integers:
                block_stub_names.append(cleaned)
        return f"{indent}/*__BLOCK_DECL__ integer {decls};*/"

    sanitized_text = BLOCK_INTEGER_RE.sub(block_decl_repl, sanitized_text)
    if block_stub_names:
        unique_names = sorted(set(block_stub_names))
        stub_lines = "\n".join(
            f"    integer {name} /*__BLOCK_STUB__*/;" for name in unique_names
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
    return sanitized_text, hints


def apply_parse_hints(text: str, hints: Dict[str, Any]) -> str:
    """Re-apply SystemVerilog qualifiers that were stripped for parsing."""
    functions_meta: Dict[str, Any] = hints.get("functions", {})
    if not functions_meta:
        return text

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

    restored_text = FUNCTION_HEADER_RE.sub(restore, text)
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
        r"\n\s*// __BLOCK_DECL_STUBS__\n(?:\s*integer\s+\w+\s*/\*__BLOCK_STUB__\*/;\n?)+",
        "\n",
        restored_text,
    )
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
        record = {
            "version": YAML_VERSION,
            "kind": "verilog_module_fallback",
            "original_path": str(source.relative_to(rtl_root)).replace("\\", "/"),
            "includes": includes,
            "summary": header_summary(text, rtl_root, source),
            "parse_error": str(error),
            "body_text": text,
        }
    else:
        tmp_path.unlink(missing_ok=True)
        record = {
            "version": YAML_VERSION,
            "kind": "verilog_module",
            "original_path": str(source.relative_to(rtl_root)).replace("\\", "/"),
            "includes": includes,
            "summary": summarise_ast(ast_root),
            "ast": ast_to_dict(ast_root),
            "parse_hints": hints,
        }
    yaml_path = yaml_root / source.relative_to(rtl_root)
    yaml_path = yaml_path.with_suffix(".yaml")
    save_text(yaml_path, yaml.safe_dump(record, sort_keys=False))


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
    for yaml_path in sorted(yaml_root.rglob("*.yaml")):
        record = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
        kind = record.get("kind")
        if kind == "verilog_module":
            restore_module(record, yaml_path, rtl_root)
        elif kind == "verilog_module_fallback":
            restore_module_fallback(record, rtl_root)
        elif kind == "verilog_header":
            restore_header(record, rtl_root)
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
