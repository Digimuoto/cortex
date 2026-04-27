---
name: haskell-code-style
description: >
  Opinionated Haskell review against branch diff. Diffs the current PR
  branch against main (or a specified base) and reviews changed .hs
  files against Cortex's production style guide. Use when: "review my
  Haskell", "style check", or any request about Haskell structure,
  patterns, or quality in the current branch.
---

# Haskell Code Style Review

Review changed Haskell code in the current branch against an opinionated
production style guide. Operates on the branch diff (like a PR review)
by default, not the entire codebase.

## Usage

```
/haskell-code-style [target...]
```

**Arguments:**

- No arguments — diffs current branch vs `main`, reviews changed `.hs` files
- `--base <branch>` — use a different base branch
- File paths — review specific files (e.g. `src/Cortex/Pulse/Executor.hs`)
- Directory paths — review all `.hs` files under the directory
  (e.g. `src-platform/Platform/DurableTask/`)

**Examples:**

```
/haskell-code-style                                         # branch diff vs main
/haskell-code-style --base develop                          # branch diff vs develop
/haskell-code-style src/Cortex/Pulse/Executor.hs            # one file
/haskell-code-style src-platform/Platform/DurableTask/      # whole directory
/haskell-code-style Executor.hs Scheduler.hs                # multiple files
```

---

## Workflow

### 1. Determine scope

Parse arguments:

**If files or directories given:**

```bash
# Files: use directly
# Directories: find all .hs files
find "$DIR" -name '*.hs' -type f
```

**If no arguments (branch-diff mode):**

```bash
BASE="${BASE:-main}"
git diff --name-only "$BASE"...HEAD -- '*.hs'
```

If no `.hs` files found, report "No Haskell files to review" and exit.

### 2. Automated pre-checks

Before any manual review, run these mechanical checks on the target
files. They catch the highest-value findings with zero ambiguity:

```bash
# Fire-and-forget Platform.Database writes (silent failures)
grep -rn '_ <- .*runTransaction\|_ <- .*runQuery\|_ <- .*withConnection' $FILES

# Wildcard matches on potentially-owned ADTs (verify each)
grep -rn '_ ->' $FILES | grep -v 'catchError\|Left _\|Right _\|Just _\|Nothing'
```

Report fire-and-forget hits as **[P1]** immediately. Wildcard hits need
manual verification — only flag if the type is declared in Cortex or
Platform source (not `Text`, `Maybe`, `Int`, `Either`, `Value`).

### 3. Load reference material

Before reviewing, read the references that are in scope for the change:

- **Always** read:
  - `references/review-rubric.md` — scoring axes and weights
  - `references/architecture.md` — module structure, ADT design, IO
    organization, layer-cake classification, boundary discipline,
    concurrency patterns
  - `references/type-conventions.md` — language extensions, phantom
    types, partial-function bans, deriving discipline, import conventions
- Read `references/refactoring-patterns.md` when the change is a
  non-trivial refactor.
- Read `references/testing-patterns.md` when any `test/**/*Spec.hs` is
  in scope (property tests, golden tests, roundtrip tests, algebraic
  laws).

Cortex's Haskell style is repo-local production-Haskell guidance. The
references should read as Cortex and Platform guidance; examples should
use `src/Cortex/...` or `src-platform/Platform/...` shapes unless they
are explicitly downstream consumer examples.

### 4. Read the code

**Branch-diff mode** (no arguments):

For each changed file, read the diff first:

```bash
git diff "$BASE"...HEAD -- "$FILE"
```

Then read the full current version for context around the changes.

**File / directory mode** (specific targets):

Read each file in full. Review the whole module against the style guide,
not just a diff — there is nothing to scope it to.

**Key difference:** directory mode reviews module health; findings
include structural debt. Classify debt as **[P2]** (track), not **[P1]**
(block merge). Only findings in *changed* code should block a PR.

### 5. Review each file

Apply the rubric from `references/review-rubric.md`. Evaluate against:

- **Correctness** — exhaustive patterns, error paths, transaction
  boundaries, `Platform.DurableTask` lifecycle handling
- **Architecture** — three-layer cake (pure / constrained effects /
  effectful wiring), pure decision vs. effectful interpretation, return
  values vs. continuations
- **Readability** — nesting depth, function length, export lists,
  comment discipline (see Cortex's `agents/context.md` principles:
  "no comments unless the why is non-obvious")
- **Type safety** — smart constructors, phantom types, `NonEmpty`, no
  partial functions (`head`, `fromJust`, `read`, `!!`, `undefined`,
  `error`, `trace` are all HLint-banned; see `.hlint.yaml`)
- **Upstream impact** — does the module's API make callers cleaner?
- **Safety** — swap-risk parameters, DB error handling, async exception
  discipline, `bracket` / `finally` correctness
- **Testing** — property tests, golden tests, roundtrip tests, law checks

Also apply Cortex's core principles (always in context; see below).

### 6. Report

Output a structured review:

```markdown
## Haskell Style Review: <branch> vs <base>

**Files reviewed:** N
**Overall:** one-sentence assessment

### <filename>

**Score:** X/10

**Findings:**
- [P1] <critical issue> — line N
- [P2] <important issue> — line N
- [style] <suggestion> — line N

**Good:**
- <positive observation>

### Summary

| File | Score | Key Issue |
|---|---|---|
| ... | X/10 | ... |

**Top priorities:**
1. <most important fix>
2. <second>
3. <third>
```

Priority levels:

- **[P1]** — Correctness bug, silent error drop, data-loss risk, Cortex
  layer-boundary violation (runtime importing reasoning layer, or
  Cortex importing a hypothetical consumer module)
- **[P2]** — Architecture issue, maintainability concern, missing error path
- **[style]** — Naming, formatting, could-be-cleaner

### 7. Offer fixes

After the review, ask whether to apply any of the findings. When the
user says yes, apply the changes following the patterns in the
reference files.

---

## Core principles (always in context)

### 1. Return values, not continuations

When a function does X then sometimes continues a loop and sometimes
exits, it's doing two jobs. Split the decision from the continuation.
Return a value; let the caller decide.

```haskell
-- BAD: attemptStage calls `go rest newState` on success, `pure outcome`
-- on failure. The continuation is hidden inside the function.

-- GOOD: attemptStage returns StageAttemptResult; the loop interprets it.
data StageAttemptResult
  = StageAdvance Aeson.Value
  | StageSkip
  | StageTerminal RunOutcome

go (stageDef : rest) state = do
  result <- attemptStage env stageDef state
  case result of
    StageAdvance newState -> go rest newState
    StageSkip             -> go rest state
    StageTerminal outcome -> pure outcome
```

### 2. Explicit environments over closures

When helpers close over 5+ variables from a `where` block, extract an
environment record and promote the helpers to top-level functions.

```haskell
-- BAD: 4 levels of where-nesting, each closing over pool, runId, config …

-- GOOD: bundle the captures, make helpers top-level.
data StageEnv = StageEnv
  { sePool     :: DB.Pool
  , seRunId    :: UUID
  , seTaskType :: Text
  , …
  }

-- Now independently testable with a mock pool.
persistStageSuccess :: StageEnv -> Text -> Aeson.Value -> IO StageAttemptResult
```

**Threshold:** >3 helpers or >3 nesting levels in a `where` → extract.

### 3. Pure decisions, effectful execution

Factor pure decision logic into its own function/ADT. The effectful
code just interprets the decision.

```haskell
-- Pure: no IO, total, exhaustive match
decideScheduleAction :: ScheduleConfig -> ExecutionOrigin -> ScheduleKind
                     -> UTCTime -> RunOutcome -> ScheduleDecision

-- Effectful: interprets the decision
applyScheduleDecisionTx :: UUID -> UTCTime -> RunOutcome
                        -> ScheduleDecision -> Transaction ()
```

Functional core / imperative shell. The decision function is trivially
testable; the interpreter is thin.

### 4. Named records for swap-risk parameters

When a function takes 2+ adjacent same-typed parameters, use a named
record. The compiler won't catch `(errType, errMsg)` swapped to
`(errMsg, errType)`.

```haskell
-- BAD: 11 positional parameters, Text/Text/Bool at the tail
handleTerminalFailure env stageDef stageName logId attemptLogId
  attempt failure stageEnd errType errMsg retryable

-- GOOD: bundle the context
data AttemptCtx = AttemptCtx
  { acStageName    :: Text
  , acLogId        :: Int64
  , acAttemptLogId :: Int64
  , acAttempt      :: Int
  , acStageEnd     :: UTCTime
  }
```

**Threshold:** >8 parameters or any adjacent same-typed pair → record.

### 5. Every DB call gets an error path

No silent drops. Every `IO (Either String a)` from `Platform.Database`
must be handled. Handling varies by context:

- **Must succeed for the run to continue** → `requireTx` pattern: log,
  fail the run, return `Nothing`.
- **Best-effort** → log warning, continue.
- **Last resort** → log error; note recovery happens via lease expiry.

```haskell
requireTx :: DB.Pool -> UUID -> Text -> IO (Either String a) -> IO (Maybe a)
requireTx pool runId context action = do
  result <- action
  case result of
    Right val -> pure (Just val)
    Left err  -> do
      logCritical context err
      failRun pool runId now "db_error" (context <> ": " <> T.pack err) True
      pure Nothing
```

### 6. Exhaustive pattern matches on owned ADTs

Never wildcard-match an ADT defined in this codebase. When someone adds
a variant, the compiler should force it to be handled everywhere.

```haskell
-- BAD
outcomeLogLevel = \case
  OutcomeCompleted -> ObsInfo
  _                -> ObsWarn  -- hides new variants

-- GOOD
outcomeLogLevel = \case
  OutcomeCompleted -> ObsInfo
  OutcomeFailed    -> ObsWarn
  OutcomeCancelled -> ObsWarn
  OutcomeTimedOut  -> ObsWarn
  OutcomeShutdown  -> ObsInfo  -- explicit: shutdown is expected, not a warning
```

### 7. Respect the Cortex layer boundary

Per ADR 0015, Cortex is a runtime substrate with a structured-reasoning
library (`Cortex.Nous`, future) on top. The runtime **never** imports
the reasoning layer, and neither the runtime nor the reasoning layer
ever imports a consumer-specific module, product binding, or host-edge
module. A cross-layer import is a **[P1]** finding.
