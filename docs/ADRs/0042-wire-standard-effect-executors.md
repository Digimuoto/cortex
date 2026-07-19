---
title: "ADR 0042 - Wire Standard Effect Executors"
description:
  "Defines stdin/stdout and argv-based command execution as standard registered host-effect
  executors for standalone Wire use, not as CorePure forms or special Wire syntax."
sidebar:
  label: "0042. Standard effect executors"
  order: 42
status: proposed
date: 2026-05-02
superseded_by: null
related:
  - docs/Architecture/01-overview.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/executor-authorities-and-execution-boundary.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0041-wire-cli-command-surface.md
  - docs/ADRs/0043-pulse-in-memory-runner.md
  - docs/ADRs/0044-wire-namespace-use-imports.md
---

# ADR 0042 - Wire Standard Effect Executors

## Status

Proposed - this ADR defines the standard-effect boundary for standalone Wire examples and tests.

## Context

Wire source composes registered authority. CorePure deliberately has no executor, host, durable
state, tool, model, time, randomness, stdin, or stdout authority. That boundary is part of the proof
story and the reason pure output equations can stay deterministic.

At the same time, a standalone Wire command needs small real effects. Useful first demos are:

```text
stdin node -> CorePure transformations -> stdout node
stdin node -> CorePure command planning -> command frontier -> CorePure gate -> stdout node
```

If stdin/stdout are added as syntax or as CorePure builtins, the pure language would gain host IO
authority. If they live only in downstream products, Cortex still lacks a first-party runnable
example. The right surface is the one Wire already uses for authority: registered executors.

## Decision

Cortex should provide a small standard executor pack for host-local effects. The first standard
effects are:

```text
use std.io.{@stdin, @stdout, @command, @readFile, @writeFile, CommandSpec, CommandResult};

@stdin
@stdout
@command
@readFile
@writeFile
```

These are ordinary Wire executors:

- they are imported with `use std.io.{...};` and referenced with `@`;
- they are admitted through the executor registry;
- they have typed node boundaries;
- they are classified as host-effecting, not pure;
- they run only when a node declaration places them in graph position.

They are not CorePure forms, not special graph syntax, and not ambient capabilities. A Wire file
that mentions them has explicitly named host IO authority.

The initial shapes are:

| Executor            | Boundary shape                        | Runtime behavior                                    |
| ------------------- | ------------------------------------- | --------------------------------------------------- |
| `@std.io.stdin`     | zero inputs, exactly one output port  | optionally prints a prompt, reads one line          |
| `@std.io.stdout`    | exactly one input port, zero outputs  | prints the input payload, optionally with newline   |
| `@std.io.command`   | zero or one input, zero or one output | executes one argv vector and captures stdout/stderr |
| `@std.io.readFile`  | zero or one input, exactly one output | reads UTF-8 text from a configured/input `path`     |
| `@std.io.writeFile` | exactly one input port, zero outputs  | writes the input payload as UTF-8 text to `path`    |

These executors should accept inert config records only. The initial stdin config may include
`prompt`. The initial stdout config may include `newline`.

`std.io.command` is argv-based, not shell-string-based. Its command spec may be supplied by CorePure
as an input record or by inert executor config. The initial command spec includes:

- `name`;
- `target`;
- `argv`;
- `cwd`;
- `stdin`;
- `required`;
- `skip`;
- `echo`;
- `successExitCodes`.

`std.io.readFile` and `std.io.writeFile` are text-only file effects. They require an explicit `path`
field, either in inert config for `readFile`/`writeFile` or as an input object for `readFile`.

The command result includes the command name, target, argv, cwd, required/skipped markers, boolean
success, status, exit code, stdout, stderr, and echo marker. A skipped command returns a structured
result instead of executing. A failed command returns `ok = false`; the local runner does not throw
away the frontier result merely because a process exits non-zero.

When `echo = true`, the local runner prints the captured stdout/stderr for that command after the
process exits. Frontier commands may run concurrently, so echoed output is emitted as one atomic
block per command rather than as interleaved live streaming.

Additional terminal behavior, streaming, binary IO, shell expansion, TTY control, environment
mutation, and interactive protocols are out of scope for v1. Shell semantics, if added later, should
use a separate and visibly authority-bearing executor such as `std.io.shell`.

Because stdout has no output ports, it is a sink node. Because stdin has no input ports, it is a
source node. Both still participate in the same node boundary normal form as every other executor:
empty ingress or empty egress is still an explicit phase, not an exception to node semantics.

## Alternatives Considered

- **Add std effects as Wire keywords** - rejected because effects should remain in the registered
  authority alphabet. Keywords would create a second authority path.
- **Add std effects as CorePure builtins** - rejected because CorePure must remain authority-free
  and deterministic. Host IO belongs behind executor admission.
- **Make command execution shell-string-based** - rejected for v1 because shell quoting, expansion,
  and injection risks are hidden in a single string. The standard command executor uses an explicit
  argv vector.
- **Keep all effects downstream** - rejected because Cortex needs a neutral standalone path for
  learning, tests, and benchmarks. Stdin/stdout and argv-based local commands are generic substrate
  effects, not domain policy.
- **Model stdin/stdout as Pulse signals or artifacts** - rejected for v1. Signals and artifacts have
  richer durable semantics. A blocking local stdin read and a stdout print are simpler host-effect
  executor bodies.

## Consequences

### Positive

- Cortex can ship runnable Wire examples without importing a downstream product.
- CorePure remains cleanly authority-free.
- Standard effects use the same registry and node-boundary machinery as all executor authority.
- The standard pack creates a small test surface for port wrapping, contract validation, source
  nodes, and sink nodes.
- `std.io.command` lets examples exercise real local build/test/doc/lint gates while still reporting
  structured results through ordinary Wire ports.

### Negative

- Cortex owns a small amount of host-effecting behavior.
- These executors are not replay-safe in the same way pure computation is; repeated local runs can
  read, print, or execute commands again.
- The standard pack must avoid growing into a general shell/filesystem/network effects library
  without separate decisions.

### Obligations

- Mark standard-effect stages as irreversible or otherwise replay-unsafe in runtime metadata.
- Keep their executor IDs stable: `std.io.stdin`, `std.io.stdout`, `std.io.command`,
  `std.io.readFile`, and `std.io.writeFile`.
- Keep the standard pack source-scoped through `use std.io.{...};` as defined by ADR 0044.
- Enforce the structural port constraints at binding time even when the registry projection admits
  author-declared ports.
- Document that std effects are for local/demo/test use unless a host explicitly chooses to expose
  them in production.
- Add tests that ensure std effects are not available through CorePure.
- Keep command execution argv-based unless a later ADR explicitly admits shell semantics.

## Traceability

- Feature keys: `capability.std_io_executors`
- Public surface: `Cortex.Wire` (the `Cortex.Wire.Std` standard pack),
  [Wire Executors and Alphabet reference](../Reference/Wire/executors-and-alphabet.md)
- Implementation: `src/Cortex/Wire/Std.hs` (the stable
  `std.io.{stdin,stdout,command,readFile,writeFile}` executor ids, the
  `std.io.CommandSpec`/`std.io.CommandResult` contracts, and the per-executor port-shape
  constraints), `app/wire/Main.hs` (the local smoke runner that executes the host-effect bodies)
- Tests: `test/Cortex/Wire/CompileSpec.hs` (lowers `use std.io.{...}` aliases to canonical executor
  and contract ids, enforces source-scope admission, and rejects bad source/sink port shapes)
- Theory/proof: none

## Related

- [Chapter 01 - Overview](../Architecture/01-overview.md)
- [Chapter 05 - Wire language](../Architecture/05-wire-language.md)
- [Wire executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Configured executors and execution boundary](../Reference/Wire/executor-authorities-and-execution-boundary.md)
- [Pure execution](../Reference/Wire/pure-execution.md)
- [ADR 0010 - Wire Closed Authority and Three-Layer Stack](0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0023 - CorePure Expression Surface](0023-corepure-expression-surface.md)
- [ADR 0024 - Typed Executor Node Interface](0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](0025-configured-executor-values.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](0039-wire-node-boundary-transform-normal-form.md)
- [ADR 0041 - Wire CLI Command Surface](0041-wire-cli-command-surface.md)
- [ADR 0043 - Pulse In-Memory Runner](0043-pulse-in-memory-runner.md)
- [ADR 0044 - Wire Namespace Use Imports](0044-wire-namespace-use-imports.md)
