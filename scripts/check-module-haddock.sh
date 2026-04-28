#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

ROOTS = ("src", "src-platform", "app", "test")
PRAGMA_RE = re.compile(r"^\{-#\s*(LANGUAGE|OPTIONS_GHC)\b.*#-\}\s*$")
MODULE_RE = re.compile(r"^module\s+([A-Z][A-Za-z0-9_'.]*(?:\.[A-Z][A-Za-z0-9_']*)*)")
FIELD_RE = re.compile(r"^(Module|Description|Copyright|License|Maintainer|Stability)\s*:\s*(.*)$")
REQUIRED_FIELDS = ("Module", "Description", "Copyright", "License", "Maintainer", "Stability")


def main(argv: list[str]) -> int:
    paths = [pathlib.Path(arg) for arg in argv if arg.endswith(".hs")]
    if not paths:
        paths = discover()

    failures: list[str] = []
    for path in paths:
        failures.extend(check_file(path))

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    return 0


def discover() -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for root in ROOTS:
        root_path = pathlib.Path(root)
        if root_path.exists():
            paths.extend(sorted(root_path.rglob("*.hs")))
    return paths


def check_file(path: pathlib.Path) -> list[str]:
    lines = path.read_text().splitlines()
    failures: list[str] = []
    index = 0
    while index < len(lines) and (lines[index].strip() == "" or PRAGMA_RE.match(lines[index].strip())):
        index += 1

    if index >= len(lines):
        return [f"{path}: missing module Haddock block"]

    if lines[index].lstrip().startswith("{- |"):
        doc_lines, after = read_block_doc(lines, index)
    elif lines[index].lstrip().startswith("-- |"):
        doc_lines, after = read_line_doc(lines, index)
    else:
        return [f"{path}:{index + 1}: expected module Haddock block after pragmas"]

    fields: dict[str, str] = {}
    context_lines: list[str] = []
    for doc_line in doc_lines:
        text = doc_line.strip()
        match = FIELD_RE.match(text)
        if match:
            fields[match.group(1)] = match.group(2).strip()
        elif text:
            context_lines.append(text)

    for field in REQUIRED_FIELDS:
        if not fields.get(field):
            failures.append(f"{path}: missing non-empty {field} field in module Haddock")

    description = fields.get("Description", "")
    if description and description[-1] not in ".!?":
        failures.append(f"{path}: Description field must end with sentence punctuation")

    if not context_lines:
        failures.append(f"{path}: module Haddock needs a context paragraph after metadata")

    declared_module = find_module_decl(lines[after:])
    module_field = fields.get("Module", "")
    if declared_module and module_field and declared_module != module_field:
        failures.append(f"{path}: Module field {module_field!r} does not match declaration {declared_module!r}")
    if not declared_module and path.name != "Spec.hs":
        failures.append(f"{path}: no module declaration found after module Haddock")

    return failures


def read_block_doc(lines: list[str], start: int) -> tuple[list[str], int]:
    doc_lines: list[str] = []
    index = start
    while index < len(lines):
        line = lines[index]
        if index == start:
            doc_lines.append(line.split("{- |", 1)[1])
        elif line.strip() == "-}":
            return doc_lines, index + 1
        else:
            doc_lines.append(line)
        index += 1
    return doc_lines, index


def read_line_doc(lines: list[str], start: int) -> tuple[list[str], int]:
    doc_lines: list[str] = []
    index = start
    first = lines[index].split("-- |", 1)[1]
    doc_lines.append(first)
    index += 1
    while index < len(lines) and lines[index].lstrip().startswith("--"):
        stripped = lines[index].lstrip()
        if stripped == "--":
            doc_lines.append("")
        elif stripped.startswith("-- "):
            doc_lines.append(stripped[3:])
        else:
            doc_lines.append(stripped[2:])
        index += 1
    return doc_lines, index


def find_module_decl(lines: list[str]) -> str | None:
    for line in lines:
        match = MODULE_RE.match(line.strip())
        if match:
            return match.group(1)
    return None


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
PY
