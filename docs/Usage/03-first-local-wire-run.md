---
title: First Local Wire Run
description: Run a ready-made Wire example locally and check its stdout and file output.
sidebar:
  label: 03. First local run
  order: 3
---

# First Local Wire Run

This page runs a `.wire` program without Postgres, a task registry, or a deployment. It is the
fastest way to see the authoring path produce output.

## Prerequisites

Build or run the `wire` CLI from the repo root:

```bash
just build-wire
```

`nix run .#wire -- ...` also rebuilds the flake output when needed.

## Run The Report Example

```bash
nix run .#wire -- run examples/wire/pure-stdlib-report.wire
```

The example compiles the source file, executes the compiled circuit in the current process, prints a
Markdown report, and writes the same report to `./wire-stdlib-report.md`.

## Check The Result

The stdout and file output should contain this report:

```text
# Wire pure stdlib report

seed: demo
rows: 5

| n | square | cube | size |
| --- | --- | --- | --- |
| 1 | 1 | 1 | SMALL |
| 2 | 4 | 8 | SMALL |
| 3 | 9 | 27 | SMALL |
| 4 | 16 | 64 | BIG |
| 5 | 25 | 125 | BIG |
```

Inspect and clean up the generated file:

```bash
sed -n '1,20p' wire-stdlib-report.md
rm -f wire-stdlib-report.md
```

## What Ran

`pure-stdlib-report.wire` uses:

- CorePure helpers to build deterministic Markdown text with `range`, `fold`, and string builtins.
- `std.io.stdout` to print the report.
- `std.io.writeFile` to write the report to disk.

The run is intentionally non-durable. It does not create a run row, checkpoint, signal wait, lease,
or resumable handle.

## Related

- [Running Wire examples](05-running-wire-examples.md)
- [Execution modes](02-execution-modes.md)
- [Pure execution](../Reference/Wire/pure-execution.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
