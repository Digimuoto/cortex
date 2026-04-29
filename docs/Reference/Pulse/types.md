---
title: "Pulse Types Reference"
description:
  "Normative Haskell types carried by Pulse: task envelope, checkpoint envelope, stage plan, retry
  policy, memory strategy."
sidebar:
  label: "Pulse types"
  order: 11
status: accepted
---

# Pulse Types Reference

These are the types Pulse carries across its durable boundary (DB rows, service-API bodies,
checkpoint payloads). They are normative: changing them requires a runtime version bump and an
explicit resume-compatibility decision.

Architectural framing is in [chapter 06](../../Architecture/06-pulse-runtime.md). The types here
state the shapes without repeating the framing.

## 1. Task envelope

```haskell
newtype TaskKind = TaskKind { unTaskKind :: Text }

data CortexTaskEnvelope = CortexTaskEnvelope
  { cortexTaskType    :: TaskKind
  , cortexTaskVersion :: Int
  , cortexTaskConfig  :: Aeson.Value
  }
```

`TaskKind` is an opaque, host-registered text tag. Cortex does not enumerate valid kinds; the
embedding application registers handlers for the kinds it supports, and Cortex treats anything else
as unregistered.

The field name `cortexTaskType` is retained for JSON wire compatibility with stored configs written
before `TaskKind` became a newtype — the envelope's `FromJSON`/`ToJSON` instance preserves the
original field name. The value is a `TaskKind`, not an enum constructor.

The envelope is the launch payload for a task. It is stored in the task definition row and decoded
at both creation time (eager validation by the Pulse API) and execution time.

### 1.1 Versioned config decoders

```haskell
type ConfigDecoder a = Int -> Aeson.Value -> Either Text a
```

Each registered task kind has a versioned decoder keyed on `cortexTaskVersion`. A decoder returns
`Left` for unknown versions rather than silently defaulting, and for breaking changes the host
provides an explicit upgrade function (`v1 -> v2`) so existing stored configs do not silently fail.

### 1.2 Extending the task kind set

New task kinds are added host-side by registering a handler and decoder under a new `TaskKind`
string. No structural changes to the launch path or to Cortex are required.

## 2. Checkpoint envelope

```haskell
data CheckpointEnvelope = CheckpointEnvelope
  { ceFormatVersion   :: Int         -- envelope format version (currently 1)
  , ceTaskType        :: Text        -- registered task-kind tag
  , ceTaskVersion     :: Int         -- task config version at write time
  , ceRuntimeVersion  :: Int         -- stage plan runtime version
  , ceCheckpointName  :: Text        -- last completed stage id
  , cePayload         :: Aeson.Value -- task-specific checkpoint state
  }
```

On resume, the executor parses the stored checkpoint payload into a `CheckpointEnvelope` and
validates all four versions against the current code. A mismatch produces a
`checkpoint_incompatible` failure — the run fails non-retryably rather than silently resuming
against a changed stage plan. Legacy checkpoints that predate the envelope format are rejected with
a descriptive error.

Checkpoint state must be serializable and resumable from stored state only. Application-level size
limit: 256 KB.

## 3. Stage identity

Stage identity splits into four typed ids so that rewrite-capable runs can separate the semantic
kind of a stage from its durable execution identity.

```haskell
class StableStageId stageId where
  stageIdToText :: stageId -> Text
```

| Id                | What it names                                                                                                |
| ----------------- | ------------------------------------------------------------------------------------------------------------ |
| `NodeId`          | Durable execution identity stored in graph state, stage logs, checkpoints, and replay checks.                |
| `stageId`         | Semantic stage kind / operator-facing label.                                                                 |
| `StageTemplateId` | Reusable serialized stage template.                                                                          |
| `StageActionId`   | Durable executable identity used to verify that resumed rewritten nodes bind to the intended runtime action. |

Linear or statically indexed stage plans may reuse `stageId` text as the checkpoint and stage-log
identity. Rewrite-capable plans must use `NodeId` as the durable identity.

## 4. Stage plan

```haskell
data StagePlan stageId = StagePlan
  { spInitialState             :: Aeson.Value
  , spCheckpointRuntimeVersion :: Int            -- bumped when stage semantics change
  , spReplayPolicy             :: ReplayPolicy
  , spInitialRewriteBudget     :: RewriteBudget
  , spTopology                 :: Relation NodeId
  , spDefinitions              :: Map NodeId (StageDefinition stageId)
  }

data StageDefinition stageId = StageDefinition
  { sdStageId         :: stageId
  , sdTemplateId      :: StageTemplateId
  , sdActionId        :: StageActionId
  , sdReplaySafety    :: StageReplaySafety       -- SafeToReplay | Irreversible
  , sdTimeoutSeconds  :: Maybe Int32             -- per-stage override
  , sdRetryPolicy     :: Maybe StageRetryPolicy
  , sdAction          :: StageAction
  , sdMemoryStrategy  :: MemoryStrategy
  }
```

`spCheckpointRuntimeVersion` is embedded in checkpoint envelopes and validated on resume. Bumping it
after a breaking stage-plan change causes in-flight runs to fail cleanly.

For rewrite-capable runs, `spInitialRewriteBudget` seeds the per-run structural rewrite budget;
Pulse persists the remaining budget in graph state and decrements it atomically with rewrite
materialization and watermark advance. Budget semantics are in
[chapter 07](../../Architecture/07-rewrites-and-materialization.md).

## 5. Retry policy

```haskell
data StageRetryPolicy = StageRetryPolicy
  { srpPredicateName :: Text                  -- durable identity of retryability logic
  , srpMaxAttempts   :: Int
  , srpBackoff       :: StageRetryBackoff     -- FixedBackoffMicros | ExponentialBackoffMicros
  , srpRetryable     :: StageFailure -> Bool
  , srpExhaustion    :: StageRetryExhaustion  -- ExhaustionFailsRun | ExhaustionSkipsStage
  }
```

`srpPredicateName` is the durable serialized identity of the retryability logic. Reusing a predicate
name for different retry semantics across compatible runtime versions is invalid.

**Timeout resolution:** per-stage `sdTimeoutSeconds` takes precedence; if unset, the task-level
`timeout_seconds` on the task definition applies.

**Retry semantics:** on a retryable failure, the executor re-runs the same stage action with the
same input state (the last checkpoint). Each attempt is recorded in the stage attempt log. When the
retry budget is exhausted, `srpExhaustion` decides whether the run fails or the stage is skipped.

**Backoff:** fixed or exponential, capped at 300 seconds. Cancellation and shutdown checks run
between retry attempts.

## 6. Memory strategy

```haskell
data MemoryStrategy
  = MemoryClassic
  | MemoryTopological !TopologicalStrategyConfig
  -- future: MemoryRetrieval, MemoryHybrid …
```

Memory is a per-node property declared on the wire, not a global run setting.

- `MemoryClassic` — the executor hands the stage exactly what its declared upstream produced
  (`scInputs`). Local causality by construction.
- `MemoryTopological cfg` — the stage runs a settled-state query at entry, using the preset,
  routing-key filter, and top-N limit from `cfg`. See the settled-state query section of
  [chapter 06](../../Architecture/06-pulse-runtime.md#settled-state-queries) for the substrate
  semantics.

The compiler emits the declared strategy under `circuitTaskNodeMetadata.memory`. The executor copies
`stageDef.sdMemoryStrategy` into `StageContext.scMemoryStrategy` at every stage attempt so actions
can dispatch on the declared surface without re-reading the plan.

## 7. Stage result

```haskell
data StageResult
  = StageComplete Aeson.Value
  | StageSuspend  SignalName
  | StageRewrite  Aeson.Value GraphRewrite
```

`StageComplete` is the ordinary case. `StageSuspend` parks the stage's node in `NodeWaiting` until a
named signal is delivered. `StageRewrite` carries both the node's durable output and a proposed
rewrite; the runtime admits the rewrite under the rules in
[chapter 07](../../Architecture/07-rewrites-and-materialization.md).

## Related

- [./schema.md](./schema.md) — DB rows that carry these types in jsonb columns.
- [./service-api.md](./service-api.md) — service endpoints that accept and return these shapes.
- [../../Architecture/06-pulse-runtime.md](../../Architecture/06-pulse-runtime.md) — runtime
  framing.
- [../../Architecture/07-rewrites-and-materialization.md](../../Architecture/07-rewrites-and-materialization.md)
  — rewrite and budget semantics.

---

_End of Pulse Types Reference._
