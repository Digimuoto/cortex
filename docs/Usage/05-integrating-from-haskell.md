---
title: Integrating From Haskell
description: Minimal shape of a Haskell consumer that compiles Wire and runs Pulse.
sidebar:
  label: 05. Integrating from Haskell
  order: 5
---

# Integrating From Haskell

A Haskell consumer typically uses Cortex in two places:

1. Compile Wire source with a strict contract and executor registry.
2. Run Pulse with a task registry that interprets admitted task kinds.

## Wire Compilation

Use `Cortex.Wire` to compile source text or parsed files:

```haskell
import Data.Text (Text)

import Cortex.Wire

compileWorkflow
  :: WireExecutorRegistry
  -> WireContractRegistry
  -> Text
  -> Either WireError CompiledCircuit
compileWorkflow executorRegistry contractRegistry =
  compileWireTextWithEnv (strictWireCompileEnv executorRegistry contractRegistry)
```

The important production choice is the `WireCompileEnv`. It is where the host decides which
contracts and executor names are valid. `executorRegistry` and `contractRegistry` are consumer-owned
values built through Cortex.Wire's executor and contract registry surface.

## Pulse Runtime

Use `Cortex.Pulse` to start the runtime:

```haskell
import Cortex.Pulse
import Cortex.Pulse.Types

main :: IO ()
main = do
  config <- loadConfig
  registry <- loadTaskRegistry
  runPulse registry config
```

`loadConfig` and `loadTaskRegistry` are consumer-owned. Cortex ships the runtime entrypoint, not a
domain-specific registry or configuration loader.

The stock `app/cortex-pulse` executable does the same thing with an empty registry. A consumer
binary uses the same substrate entrypoint with real task definitions.

## Boundary Rule

Cortex should stay provider-neutral. Put model clients, product tools, document renderers, and
domain policies in the consumer library. Register only the executor authority Cortex needs to
compile and run the graph.

See [Consumers/](../Consumers/) for downstream binding examples.
