---
title: "ADR 0041 - Wire CLI Command Surface"
description:
  "Defines `wire` as the first-party command for compiling and running Wire programs, separate from
  the durable `cortex-pulse` service."
sidebar:
  label: "0041. Wire CLI command"
  order: 41
status: proposed
date: 2026-05-02
superseded_by: null
related:
  - docs/Architecture/01-overview.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Usage/index.md
  - docs/Usage/01-quickstart.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0042-wire-standard-effect-executors.md
  - docs/ADRs/0043-pulse-in-memory-runner.md
---

# ADR 0041 - Wire CLI Command Surface

## Status

Proposed - this ADR defines the command surface for the standalone Wire track. It does not implement
the command.

## Context

Cortex is a standalone substrate, but the current executable story is split:

- Wire can parse and compile source into a compiled circuit.
- Pulse can execute stage plans through the Haskell library and the durable `cortex-pulse` service.
- The stock `cortex-pulse` binary intentionally starts with an empty task registry.
- Useful executor bindings have mostly appeared in downstream applications.

That is correct for production embedding, but it leaves no first-party path for learning, demos,
smoke tests, or small local Wire programs. A user should be able to write a `.wire` file, compile
it, inspect the compiled artifact, and run a small program without creating a downstream service.

The command must not blur the architectural boundary. The durable runtime service remains Pulse. The
Wire command is a developer and local-execution surface over the compiler, standard executor
bindings, and an explicit local runner mode.

## Decision

Cortex should provide a first-party command named `wire`.

The initial command surface is:

```bash
wire FILE
wire build FILE
wire run FILE
```

`wire FILE` is the default local experience. It is shorthand for `wire run FILE`, so a flake user
can run a checked-out example with:

```bash
nix run .#wire examples/wire/interactive-priority-planner.wire
```

`wire build FILE` compiles Wire source using the standard Cortex registry and writes the compiled
`CompiledCircuit` JSON artifact. By default it writes pretty JSON to stdout. `--out FILE` may write
the artifact to disk.

`wire run FILE` compiles the same source, lowers the compiled circuit through the standard Cortex
bindings, and executes it through the in-memory Pulse runner defined by ADR 0043.

The command is intentionally shaped like a small command family rather than a one-off demo binary.
Future subcommands can add checks, formatting, package/build-cache behavior, registry inspection, or
durable submission without changing the executable name.

`wire` and `cortex-pulse` have different roles:

| Command        | Role                                                                   |
| -------------- | ---------------------------------------------------------------------- |
| `wire`         | Work with Wire source locally: compile, inspect, run, test, benchmark. |
| `cortex-pulse` | Run the durable Pulse service with a host-supplied task registry.      |

The first implementation should expose `wire` through the same build surfaces as other executables:
the Cabal executable stanza, Nix package/app output, and a `just build-wire` convenience target.

## Alternatives Considered

- **Extend `cortex-pulse` with Wire subcommands** - rejected because `cortex-pulse` is the durable
  service shell. Mixing local source tooling into it would make the service command look like the
  authoring command and would obscure the empty-registry boundary.
- **Name the command `cortex-wire`** - rejected because the user-facing language command should be
  short and stable. The package and flake output can still make the Cortex origin clear.
- **Only provide Haskell library APIs** - rejected because it keeps Cortex technically standalone
  while preventing basic standalone use, tutorials, CLI smoke tests, and local benchmark runs.
- **Make `wire build` produce a new runnable bundle format immediately** - rejected for v1. The
  existing compiled circuit JSON is the compiler artifact already present in the system. A richer
  bundle can be added later if execution needs cached registry metadata or lockfiles.

## Consequences

### Positive

- Cortex gains a standalone authoring and demo path that does not depend on a downstream product.
- `CompiledCircuit` becomes an inspectable artifact for examples, tests, and debugging.
- The local run path can dogfood Wire, CorePure, node-boundary wrapping, and simple host effects.
- Future benchmarking can target a stable command instead of ad hoc test harnesses.

### Negative

- Cortex now owns CLI UX compatibility for the `wire` command.
- The command needs careful docs so users do not confuse local in-memory runs with durable Pulse
  service execution.
- Adding a Haskell executable changes Cabal and materialized Nix plans.

### Obligations

- Implement `wire build`, `wire run`, and the bare-file `wire FILE` shorthand as small wrappers
  around library APIs, not as a second compiler or second runtime.
- Keep `wire run` honest about its execution mode: local, in-memory, and non-durable unless a future
  subcommand explicitly targets the durable service.
- Document the relationship between `wire`, `cortex-pulse`, compiled circuits, and downstream
  bindings in the Usage guide.
- Add CLI tests or smoke tests that run without Postgres.

## Traceability

- Feature keys: `packaging.wire_cli`
- Public surface: the first-party `wire` executable (`app/wire`); see the
  [Usage guide](../Usage/index.md) and [Quickstart](../Usage/01-quickstart.md)
- Implementation: `app/wire/Main.hs` (the `wire FILE` / `wire build` / `wire run` / `wire fmt`
  command family); the executable is declared in `cortex.cabal`
- Tests: none — the CLI dispatch in `app/wire/Main.hs` has no process-level smoke test; the
  libraries it wraps are covered by `test/Cortex/Wire/CompileSpec.hs`,
  `test/Cortex/Wire/RuntimeSpec.hs`, and `test/Cortex/Wire/FormatSpec.hs`
- Theory/proof: none

## Related

- [Chapter 01 - Overview](../Architecture/01-overview.md)
- [Chapter 05 - Wire language](../Architecture/05-wire-language.md)
- [Chapter 06 - Pulse runtime](../Architecture/06-pulse-runtime.md)
- [Wire grammar](../Reference/Wire/grammar.md)
- [Wire executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Usage guide](../Usage/index.md)
- [Quickstart](../Usage/01-quickstart.md)
- [ADR 0010 - Wire Closed Authority and Three-Layer Stack](0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0021 - Wire Source Elaborates to Circuits](0021-wire-source-elaborates-to-circuits.md)
- [ADR 0024 - Typed Executor Node Interface](0024-typed-executor-node-interface.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](0039-wire-node-boundary-transform-normal-form.md)
- [ADR 0042 - Wire Standard Effect Executors](0042-wire-standard-effect-executors.md)
- [ADR 0043 - Pulse In-Memory Runner](0043-pulse-in-memory-runner.md)
