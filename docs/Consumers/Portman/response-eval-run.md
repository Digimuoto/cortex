---
title: "ResponseEvalRun on Pulse"
description: "Detailed design for DIG-320 and DIG-331: typed Pulse outcomes, ResponseEvalRun execution, and incremental eval persistence"
---

# ResponseEvalRun on Pulse

Status: **Proposed detailed design**

Last updated: **April 1, 2026** - `DIG-320` / `DIG-331`.

This page turns the high-level Pulse spec into an implementation-facing design
for the first durable task. It covers two linked changes:

- `DIG-331`: replace `Bool` executor results with a typed `PulseRunOutcome`
- `DIG-320`: implement `ResponseEvalRun` as the first real Pulse task, with
  checkpointed batch execution and incremental persistence to Portman's eval
  tables

The design follows a few `restate` patterns that fit Portman well:

- explicit lifecycle states instead of overloaded booleans
- cancel and shutdown treated as different runtime outcomes
- resume from durable cursor state, not from inferred control flow
- replay/resume reads only the state needed for the next step

It does **not** copy `restate`'s full journaled command architecture. Pulse is
smaller and should stay smaller.

The generic typing rules behind this design now live in Cortex's architecture
and reference docs; this page keeps the Portman-specific eval persistence
design separate from those substrate rules.

## Summary

The core decisions are:

- Pulse scheduler/executor communication becomes a typed protocol:

```haskell
data PulseRunOutcome
  = RunCompleted
  | RunFailed
  | RunCancelled
  | RunShutdown
```

- `ResponseEvalRun` stops using the current stringly-typed
  `[(Text, StageAction)]` shell. It gets a typed task driver with:
  - typed config
  - typed checkpoint
  - typed stage/phase model
  - typed error taxonomy
- `assistant_eval_runs.eval_run_id` is the durable `pulse.runs.run_id` for
  `ResponseEvalRun`. One UUID should identify the same run everywhere:
  Pulse, observability, usage events, and eval scorecards.
- Pulse does not write Portman tables directly. It calls internal Portman
  host-action endpoints for:
  - eval run start
  - eval batch persistence
  - eval run finalization
- Batch persistence is idempotent. Case rows are inserted with conflict
  protection, and aggregate counts are recomputed from stored case rows rather
  than trusted from the caller.

## Why The Current Shape Is Not Enough

Today the runtime is still only a skeleton:

- `executeTask` and `resumeTask` return `Bool`, which collapses
  Completed/failed/cancelled/shutdown into one bit
- `finalizeTaskSchedule` must infer shutdown semantics indirectly
- stage selection is `Text -> [(Text, StageAction)]`
- checkpoint state is untyped `Aeson.Value` all the way through the executor
- `assistant_eval_runs` is modeled as one-shot ingest:
  - `completed_at` is required
  - admin ingest expects the whole run and all case results at once
  - there is no durable lifecycle for `running`, `cancelled`, or partial
    progress

That is acceptable for `DIG-319`, but it is the wrong foundation for the first
real durable task.

## Design Goals

1. Make runtime outcomes explicit and total.
2. Make `ResponseEvalRun` the first task that is typed end-to-end, not just at
   the envelope edge.
3. Preserve partial results across cancellation, timeout, failure, and resume.
4. Keep Pulse/Portman ownership clean: Pulse owns execution; Portman owns eval
   tables and admin surfaces.
5. Keep the first task narrow enough that it proves the runtime without
   dragging in portfolio-domain complexity.

## DIG-331: Typed Pulse Outcome

### Runtime contract

Add to `Cortex.Pulse.Types`:

```haskell
data PulseRunOutcome
  = RunCompleted
  | RunFailed
  | RunCancelled
  | RunShutdown
  deriving stock (Eq, Show)
```

This type is intentionally small. The detailed error, cancellation reason, and
retryability are already persisted in Pulse storage and emitted through
observability. The scheduler only needs to know which scheduling branch to
take next.

### Semantics

`RunCompleted`
- all task stages finished successfully
- final schedule advancement should run

`RunFailed`
- task reached a terminal failure state
- final schedule advancement should run with failure semantics

`RunCancelled`
- operator or timeout cancellation reached a clean terminal state
- final schedule advancement should run as cancelled, not as failed

`RunShutdown`
- the process drained before the next safe execution boundary
- no schedule finalization should run
- the run stays resumable in Pulse-owned storage

### Why this is better than `Bool`

- no shutdown side-channel
- no `False` ambiguity
- no extra scheduler `shutdownFlag` guard after execution
- cancellation becomes first-class instead of "failed but not really"

### Scheduler contract

`finalizeTaskSchedule` must dispatch directly on `PulseRunOutcome`:

```haskell
finalizeTaskSchedule :: DB.Pool -> PulseTaskDefinitionRow Result -> UTCTime -> PulseRunOutcome -> IO ()
```

Rules:

- `RunShutdown`: do nothing
- `RunCompleted`: complete one-off or advance cron with success
- `RunFailed`: back off one-off or advance cron with failed status
- `RunCancelled`: treat like a terminal non-success outcome, but keep the
  stored run status as `cancelled`

The important point is that shutdown is no longer inferred from mutable process
state after the fact. It is an explicit executor outcome.

## DIG-320: ResponseEvalRun Task Model

### Task config

Introduce a typed config decoder instead of reading raw JSON in the task body:

```haskell
data ResponseEvalRunConfig = ResponseEvalRunConfig
  { rerCorpusId :: Text
  , rerCorpusVersion :: Text
  , rerSuiteId :: Text
  , rerRunSource :: EvalRunSource
  , rerJudgeProvider :: Maybe Text
  , rerJudgeModel :: Maybe Text
  , rerBatchSize :: Natural
  , rerGitSha :: Text
  , rerGitBranch :: Maybe Text
  , rerGitPrNumber :: Maybe Int32
  , rerCaseFilter :: Maybe [Text]
  }
```

Notes:

- batch size must be validated as `> 0`
- git metadata belongs in the task config because it is part of the eval run's
  durable provenance
- case filtering stays optional and explicit; the first version should not
  encode ad hoc case selection inside opaque metadata blobs

### Typed status and error vocabulary

Do not keep eval status and error handling as arbitrary `Text` inside the task
implementation. Define codec-backed Haskell sums:

```haskell
data EvalRunStatus
  = EvalRunning
  | EvalCompleted
  | EvalFailed
  | EvalCancelled

data ResponseEvalErrorType
  = EvalModelTimeout
  | EvalModelRefusal
  | EvalJudgeFailure
  | EvalCaseDecodeError
  | EvalBatchPersistError
  | EvalInternalError
```

Persist as snake_case text only at the storage boundary.

## Typed Driver Instead Of `[(Text, StageAction)]`

`ResponseEvalRun` is the forcing function for a better task boundary. The
current `Text -> [(Text, StageAction)]` API is too weak for:

- typed configs
- typed checkpoints
- dynamic batch cursors
- task-specific resume rules

The replacement should still stay simple:

```haskell
data SomePulseTaskDriver
  = forall task. PulseTask task => SomePulseTaskDriver (PulseTaskDriver task)

data PulseTaskDriver task = PulseTaskDriver
  { ptdTaskType :: CortexTaskType
  , ptdDecodeConfig :: Int -> Aeson.Value -> Either Text (TaskConfig task)
  , ptdStart :: TaskContext -> TaskConfig task -> IO (TaskStep task)
  , ptdResume :: TaskContext -> TaskConfig task -> TaskCheckpoint task -> IO (TaskStep task)
  }

data TaskStep task
  = TaskContinue (TaskCheckpoint task)
  | TaskFinish PulseRunOutcome
```

This is intentionally not a general workflow DSL. It is a typed task registry.
Type erasure happens once at the scheduler/executor boundary, not everywhere.

## How Far To Push The State Machine Into Types

Yes: Haskell can encode this state machine cleanly.

The right split is:

- use the type system aggressively for in-memory execution states and
  transitions
- treat the checkpoint/DB boundary as a decode boundary that must be validated
  back into a legal runtime state

That means Pulse should prefer a typed transition model such as:

```haskell
data EvalState
  = EvalNeedSetup ResponseEvalRunConfig
  | EvalRunning ResponseEvalCheckpoint
  | EvalReadyToFinalize ResponseEvalCheckpoint
  | EvalFinished PulseRunOutcome
```

or, if we want stricter compile-time transition control inside the task
 implementation, a GADT/phantom-state encoding:

```haskell
data EvalPhase = NeedSetup | Running | ReadyToFinalize | Finished

data EvalState (phase :: EvalPhase) where
  NeedSetupState :: ResponseEvalRunConfig -> EvalState 'NeedSetup
  RunningState :: ResponseEvalCheckpoint -> EvalState 'Running
  ReadyToFinalizeState :: ResponseEvalCheckpoint -> EvalState 'ReadyToFinalize
  FinishedState :: PulseRunOutcome -> EvalState 'Finished
```

Recommendation:

- use ordinary ADTs for persisted checkpoint data
- use typed transition functions or a small GADT for in-memory task execution
- do not try to pretend the JSON checkpoint itself carries compile-time proof

Once state crosses the persistence boundary, the guarantee comes from:

1. decoding into a typed checkpoint
2. validating that checkpoint against the task config and known phase model
3. resuming only from a legal constructor

That is the `restate` lesson worth copying: explicit legal states and resume
 rules, not necessarily maximal type-level cleverness everywhere.

## ResponseEvalRun Phases And Checkpoint

### Phase model

`ResponseEvalRun` only needs three coarse phases:

```haskell
data ResponseEvalPhase
  = EvalSetup
  | EvalExecuteBatches
  | EvalFinalize
```

These are coarse human-facing phases, not individual per-case steps.

### Checkpoint model

The checkpoint is where detailed resume state lives:

```haskell
data ResponseEvalCheckpoint = ResponseEvalCheckpoint
  { recPhase :: ResponseEvalPhase
  , recRunRowCreated :: Bool
  , recNextBatchIndex :: Natural
  , recCompletedCaseCount :: Int32
  , recLastCompletedCaseId :: Maybe Text
  }
```

Rules:

- `recRunRowCreated` prevents duplicate start-of-run initialization after
  resume/retry ambiguity
- `recNextBatchIndex` is the durable cursor
- the checkpoint is the source of truth for "where execution resumes next"
- the eval run row is a projection for operators; it is not the resume source

This is the direct place where Pulse should copy `restate`'s "resume from
 durable cursor state" discipline.

## Portman Eval Persistence Model

### Ownership

Pulse owns:

- run execution
- cancellation checks
- checkpoint cursor
- stage log
- observability

Portman owns:

- `assistant_eval_runs`
- `assistant_eval_case_results`
- admin read APIs and scorecards

Pulse must therefore persist through internal Portman APIs, not direct DB
 writes.

### Host-action endpoints

Add dedicated internal endpoints for eval persistence:

- `POST /internal/v1/Pulse/evals/runs/start`
- `POST /internal/v1/Pulse/evals/runs/:runId/batches`
- `POST /internal/v1/Pulse/evals/runs/:runId/finalize`

`start`
- create or idempotently confirm the `assistant_eval_runs` row
- set status `running`
- initialize counts to zero

`batches`
- insert completed case results for one batch
- update aggregate counts on the run row
- stay in status `running`

`finalize`
- mark the run as `completed`, `failed`, or `cancelled`
- set `completed_at`
- persist final aggregate counts

The existing admin ingest endpoint can remain for manual or external imports,
but durable Pulse execution should not go through the admin surface.

### Idempotency

Every mutating call uses an idempotency key:

- `<run_id>/setup/start`
- `<run_id>/evaluate/batch/<batch_index>`
- `<run_id>/finalize/<status>`

For batch writes, the implementation should be naturally idempotent as well:

- `assistant_eval_case_results` inserts use conflict protection on
  `(eval_run_id, case_id, model)`
- aggregate counts are recomputed from stored case rows after insert

That means a replayed batch cannot double-count progress even if the caller
 does not know whether the previous HTTP call succeeded.

## Schema Changes

`assistant_eval_runs` needs to support in-progress lifecycle state.

### Required changes

1. Make `completed_at` nullable.
2. Add `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.

Without these changes, a run cannot exist durably in `running` state.

### Deliberate non-changes

Do **not** add a duplicate "last completed batch" column. That cursor belongs
 in the Pulse checkpoint, not the Portman projection row.

Do **not** add a separate Pulse-to-eval join key. `eval_run_id` should equal
 the Pulse `run_id`.

### API fallout

The admin eval response types currently assume `completed_at :: UTCTime`.
Those fields must become `Maybe UTCTime` for run detail and run summary types.

That is the correct API shape anyway because `running` rows are part of the
 acceptance criteria.

## Execution Flow

### Setup

1. Decode `ResponseEvalRunConfig`.
2. Resolve the corpus and suite through existing eval infrastructure.
3. Persist the `assistant_eval_runs` row with:
   - `eval_run_id = pulse run_id`
   - status `running`
   - zero counts
4. Write checkpoint:
   - `phase = EvalExecuteBatches`
   - `runRowCreated = True`
   - `nextBatchIndex = 0`

### Execute batches

For each batch:

1. Check shutdown flag before starting the next batch.
2. Check cancellation flag before starting the next batch.
3. Execute the batch using existing eval/judge plumbing.
4. Persist the batch through Portman internal API.
5. Write checkpoint with incremented `nextBatchIndex`.
6. Emit observability event with:
   - `run_id`
   - `stage = evaluate_batch`
   - `batch_index`
   - `completed_cases`
   - `total_cases`

If the process dies after step 4 but before step 5, the batch may be retried on
 resume; idempotent batch writes make that safe.

### Finalize

On success:

- finalize eval run as `completed`
- return `RunCompleted`

On operator cancellation:

- finalize eval run as `cancelled`
- preserve all completed case results
- return `RunCancelled`

On timeout:

- treat like cancellation at the task lifecycle level
- classify separately in stage log / error taxonomy
- return `RunCancelled`

On failure:

- finalize eval run as `failed`
- preserve completed case results
- record structured failure in Pulse storage / logs
- return `RunFailed`

On shutdown drain:

- do not finalize
- return `RunShutdown`

## Observability And Usage Correlation

Because `assistant_eval_runs.eval_run_id` equals the Pulse `run_id`, model
 usage correlation becomes straightforward:

- Pulse creates an observability context with `run_id`
- model usage inserts already propagate `run_id` from observability context
- `assistant_usage_events.run_id` now points at the durable eval run directly

No extra correlation table is needed.

Required event fields during batch execution:

- `service = cortex-pulse`
- `operation = pulse.response_eval_run.batch`
- `run_id`
- `stage`
- `attempt`
- `model`
- `error_type` / `retryable` on failure

## What We Borrow From Restate

Useful patterns from `restate`:

- explicit invocation status model instead of one generic "not successful"
  branch
- distinct cancel vs kill semantics
- suspend/resume driven by durable state, not by reconstructing control flow
- lazy replay boundaries

Patterns we should not copy:

- general journal entry protocol
- command/event engine complexity
- dynamic deployment-routing machinery

Pulse only needs the narrow discipline, not the full distributed runtime.

## File-Level Plan

### DIG-331 first

- `src/Cortex/Pulse/Types.hs`
  - add `PulseRunOutcome`
- `src/Cortex/Pulse/Executor.hs`
  - return `PulseRunOutcome`
  - stop encoding shutdown/cancel/failure in `Bool`
- `src/Cortex/Pulse/Scheduler.hs`
  - dispatch finalization by `PulseRunOutcome`
- `src/Cortex/Pulse.hs`
  - propagate the typed outcome during startup recovery too

### DIG-320 second

- `src/Cortex/Pulse/Task/ResponseEvalRun.hs`
  - typed config, checkpoint, execution driver
- `src/Cortex/Pulse/Task/Registry.hs`
  - task-type to driver dispatch
- `src/Portman/Database/Query/AssistantEval.hs`
  - split one-shot ingest from mutable lifecycle operations
- `src/Portman/Server/Admin/API.hs`
  - allow `Maybe UTCTime` for incomplete runs
- `src/Portman/Server/Admin/Handler.hs`
  - keep external ingest path, but adjust read models
- new internal Pulse host-action handlers under `src/Portman/Server/Handler/Internal/...`
- `sql/schema.sql`
  - make `assistant_eval_runs.completed_at` nullable
  - add `updated_at`

## Recommended Delivery Order

1. Land `DIG-331` by itself.
2. Land schema/API changes for in-progress eval rows.
3. Add Portman internal eval persistence endpoints.
4. Add typed `ResponseEvalRun` driver on Pulse.
5. Add end-to-end tests for:
   - batch checkpoint resume
   - cancellation between batches
   - timeout treated as cancellation
   - repeated batch persistence is idempotent
   - usage events linked by `run_id`

## Open Choices

These should be decided once during implementation and then fixed in code:

- whether `rerCaseFilter` should stay `[Text]` or become a dedicated selector
  sum type
- whether timeout should surface as `RunCancelled` plus timeout error taxonomy,
  or as a separate `RunTimedOut` outcome later
- whether batch summaries belong in checkpoint `summary` JSON for operator UX,
  or only in observability events

The current recommendation is:

- keep timeout under `RunCancelled` for scheduler simplicity
- keep checkpoint summaries small
- keep the task config narrow and explicit
