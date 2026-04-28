<p align="center">
  <img src="assets/cortex-readme-banner.png" alt="Cortex" />
</p>

<p align="center">
  <a href="https://github.com/Digimuoto/cortex/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Digimuoto/cortex/actions/workflows/ci.yml/badge.svg" /></a>
  <a href="https://digimuoto.github.io/cortex/"><img alt="Docs" src="https://github.com/Digimuoto/cortex/actions/workflows/docs.yml/badge.svg" /></a>
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
  <img alt="Build: Nix" src="https://img.shields.io/badge/build-Nix-5277C3" />
</p>

# Cortex

Cortex is a standalone AI substrate: a typed topology layer, a source language for composing that
topology, and a durable runtime for executing it.

The core layers are:

| Layer       | Role                                                          |
| ----------- | ------------------------------------------------------------- |
| **Graph**   | Pure topology: vertices, overlay, connect, and graph laws.    |
| **Circuit** | Validated executable topology with typed port compatibility.  |
| **Wire**    | Source language and rewrite notation for authoring circuits.  |
| **Pulse**   | Durable execution, checkpoints, events, memory, and rewrites. |

Downstream products bind Cortex to their own domain semantics, tools, product policy, operators,
transport, and persistence. Cortex owns the reusable substrate.

## Minimal Wire

Wire composes registered authority. Executors, contracts, tools, and payload meaning are registered
outside the language; Wire describes how those typed pieces connect.

```wire
contract Plan;
contract Evidence;
contract Report;

node plan   : -> Plan             = @llm.planner {};
node gather : <- Plan -> Evidence = @tool.search {};
node write  : <- Evidence -> Report = @llm.writer {};

plan => gather => write
```

## Documentation

- [Docs landing](https://digimuoto.github.io/cortex/) - architecture, reference, ADRs, roadmap, and
  consumer bindings.
- [Stable canon](https://digimuoto.github.io/cortex/#stable-canon) - architecture, reference, ADRs,
  and canonical docs.
- [Working artifacts](https://digimuoto.github.io/cortex/#working-artifacts) - roadmap, research
  notes, experiments, handoffs, and templates.
- [Start here](https://digimuoto.github.io/cortex/#start-here) - the intended first reading path
  through the published docs.
- [Consumer examples](https://digimuoto.github.io/cortex/#consumer-examples) - downstream binding
  examples.

## Repository

```text
src/Cortex/               Graph, Circuit, Wire, Pulse, memory, capabilities
src-platform/Platform/    Runtime substrate helpers
app/cortex-pulse/         Pulse executor binary
editors/tree-sitter-wire/ Wire tree-sitter grammar
theory/                   Lean mechanization scaffold
docs/                     Published Cortex documentation
agents/                   Provider-neutral agent context and skills
```

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
