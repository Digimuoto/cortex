---
title: Running Wire Examples
description: Choose a Wire example by runtime mode, prerequisites, and local side effects.
sidebar:
  label: 05. Wire examples
  order: 5
---

# Running Wire Examples

The examples under `examples/wire/` are not all the same kind of runnable. Read the file header
first: it usually names the intended command and any provider or local side effect.

## Example Classes

| Class                                   | Examples                                                | How to run                                                              | Notes                                                                                             |
| --------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| First local smoke                       | `pure-stdlib-report.wire`                               | `nix run .#wire -- run examples/wire/pure-stdlib-report.wire`           | Prints and writes `wire-stdlib-report.md`.                                                        |
| Interactive local                       | `interactive-priority-planner.wire`                     | `nix run .#wire -- run examples/wire/interactive-priority-planner.wire` | Reads one stdin line and prints a plan.                                                           |
| Shell-backed local                      | `mini-build-system.wire`, `c-build/c-build.wire`        | `nix run .#wire -- run FILE`                                            | Executes local commands through `std.io.command`. Read the header before running.                 |
| Topology or consumer-authority examples | `dashboard-request.wire`, `bounded-shard-analysis.wire` | Compile or inspect with an appropriate registry                         | They name executors such as `@http.*` or `@review.*`; local `wire run` has no authority for them. |
| Quantum package examples                | `quantum-*.wire`, `qec-repetition-realize.wire`         | Use package manifests and a quantum consumer binding                    | They require quantum namespaces and a simulator or provider binding.                              |
| Quantum experiment app                  | `quantum-eraser-experiment.wire`                        | `nix run .#wire-quantum-eraser -- --confirm-hardware`                   | The app owns provider credentials and hardware confirmation.                                      |
| Runtime-bounded kernel                  | `runtime-bounded-paginated-ingest/page-kernel.wire`     | Compile as a kernel for Pulse/host registration                         | The loop is provisioned by Pulse and the host, not by recursive Wire source.                      |

## Local Side Effects

Standard `std.io` leaves can touch your terminal, filesystem, or shell:

- `std.io.stdin` prompts and reads one line.
- `std.io.stdout` prints a value.
- `std.io.command` executes an argv vector.
- `std.io.readFile` reads UTF-8 text.
- `std.io.writeFile` writes UTF-8 text.

Use the first local report example when you want a deterministic smoke run with only stdout and one
known generated file. Use shell-backed examples only when you are comfortable with the commands in
the source.

## Package And Registry Requirements

`use std.io.{...}` imports standard local executor names into source scope. Extension namespaces
such as quantum packages require package manifests at compile time. Product-specific executor names
require a consumer registry and runtime authority.

## Related

- [First local Wire run](03-first-local-wire-run.md)
- [Package manifests and extensions](06-package-manifests-and-extensions.md)
- [Quantum consumer](../Consumers/Quantum.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
