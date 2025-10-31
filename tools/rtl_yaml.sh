#!/usr/bin/env bash
set -euo pipefail

# Wrapper around verilog_yaml_bridge.py that scrubs any parser artefacts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
BRIDGE_SCRIPT="${REPO_ROOT}/tools/verilog_yaml_bridge.py"

usage() {
  cat <<'EOF'
Usage: tools/rtl_yaml.sh <export|restore> [bridge-args...]

Commands:
  export   Mirror rtl/ (excluding rtl/legacy/) into rtl.yaml/.
  restore  Rebuild rtl/ from rtl.yaml/.

You can pass additional arguments after the command to override defaults.
Examples:
  tools/rtl_yaml.sh export --exclude legacy another_dir
  tools/rtl_yaml.sh restore --rtl-root rtl_out
EOF
}

clean_parser_cache() {
  rm -f "${REPO_ROOT}/parser.out" "${REPO_ROOT}/parsetab.py"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

command="$1"
shift

case "${command}" in
  export)
    "${PYTHON_BIN}" "${BRIDGE_SCRIPT}" export \
      --rtl-root "${REPO_ROOT}/rtl" \
      --yaml-root "${REPO_ROOT}/rtl.yaml" \
      --exclude legacy "$@"
    ;;
  restore)
    "${PYTHON_BIN}" "${BRIDGE_SCRIPT}" restore \
      --yaml-root "${REPO_ROOT}/rtl.yaml" \
      --rtl-root "${REPO_ROOT}/rtl" "$@"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage
    exit 1
    ;;
esac

clean_parser_cache
