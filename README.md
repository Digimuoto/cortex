# Cortex

[![CI](https://github.com/Digimuoto/cortex/actions/workflows/ci.yml/badge.svg)](https://github.com/Digimuoto/cortex/actions/workflows/ci.yml)
[![Docs](https://github.com/Digimuoto/cortex/actions/workflows/docs.yml/badge.svg)](https://digimuoto.github.io/cortex/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![Build: Nix](https://img.shields.io/badge/build-Nix-5277C3)

Cortex is a durable runtime substrate for typed graph programs. It provides:

- **Wire**, a small source language for contract-checked dataflow graphs;
- **Pulse**, a runtime for executing ready frontiers and durable continuations;
- **Algebra**, the graph laws underneath Wire and Pulse;
- **Capability** and **Artifact** boundaries for registered authority and durable outputs.

The point is to make topology explicit: pure planning stays pure, external authority stays
registered, and independent nodes can run as a frontier.

## Wire

<!-- GitHub does not load repo-local Wire highlighting for README fences; `haskell` is a readable fallback. -->

```haskell
contract UserInput;
contract Greeting;

node read_name
  -> name: UserInput = @cortex.io.stdin { cfg = { prompt = "Name: "; }; };

node greet
  <- name: UserInput  -> greeting: Greeting = "Hello, ${name}.";

node print_greeting
  <- greeting: Greeting = @cortex.io.stdout { payload = greeting; cfg = { newline = true; }; };

read_name
  => greet
  => print_greeting
```

The connect operator `=>` advances causal time.

## Try It

```bash
nix run .#wire -- run examples/wire/interactive-priority-planner.wire
nix run .#wire -- run examples/wire/mini-build-system.wire
```

All normal development goes through Nix and `just`:

```bash
just build
just test
just docs-build
just lean-build
```

## Documentation

The full guide and reference live in the published docs:

- [Start here](https://digimuoto.github.io/cortex/Usage/) for practical usage.
- [Architecture](https://digimuoto.github.io/cortex/Architecture/) for the substrate model.
- [Wire reference](https://digimuoto.github.io/cortex/Reference/Wire/) for syntax and semantics.
- [Proof status](https://digimuoto.github.io/cortex/Reference/proof-status/) for the current
  mechanized surface.
- [ADRs](https://digimuoto.github.io/cortex/ADRs/) for design decisions.

## Repository

```text
src/Cortex/               Cortex substrate library
app/wire/                 Local Wire command
app/cortex-pulse/         Pulse executor shell
examples/wire/            Runnable Wire examples
editors/tree-sitter-wire/ Wire tree-sitter grammar
theory/                   Lean mechanization
docs/                     Published documentation
```

Cortex depends on `Digimuoto/haskell-platform` through the `haskell-platform-src` flake input.
Downstream systems bind Cortex to their own executors, tools, policies, operators, and persistence.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
