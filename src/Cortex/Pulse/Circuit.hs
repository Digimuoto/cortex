{- |
Module      : Cortex.Pulse.Circuit
Description : Run a compiled Wire circuit through the durable Pulse executor.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Generic production entrypoint that lowers a compiled Wire circuit to a stage plan
and drives it through the durable Pulse executor — fresh run and resume —
including @select(...)@ over committed output variants (ADR 0062, GitHub #321).

Branch selection is by committed variant label: a producer commits exactly one
labelled variant ('Cortex.Wire.Value.wireValuePort'), and the lowered condition
stages route it to the matching arm via 'committedVariantConditionBinding'.
Downstream callers supply the task-node bindings (their effect resolution) through
'CircuitPulseBinder'; this module supplies only the lowering and the durable
execution glue, never effect or capability resolution.

A lowered plan embeds each condition as a runnable stage and additionally carries a
parallel 'StageLatentCondition' encoding for provenance/recovery. For every
condition this executor runs, that encoding is covered by an embedded stage. A
latent condition with no covering stage is a deferred control form this executor
cannot run, so it is rejected loudly ('CircuitRunUnsupportedLatentConditions')
rather than executed partially. With the current compiler this never fires; it
guards the public entrypoint against future deferred forms.
-}
module Cortex.Pulse.Circuit
  ( CircuitRunError (..)
  , runCompiledCircuit
  , resumeCompiledCircuit
  , lowerRunnableCircuit
  , ensureRunnable
  )
where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.UUID (UUID)
import Rel8 (Result)

import Cortex.Pulse.Executor (TaskContext, executeStagePlan, resumeStagePlan)
import Cortex.Pulse.Node (NodeId)
import Cortex.Pulse.Plan
  ( SomeStagePlan (..)
  , StageLatentCondition (..)
  , slbNestedConditions
  , slbNodes
  , spDefinitions
  )
import Cortex.Pulse.Schema (PulseTaskDefinitionRow)
import Cortex.Wire.Circuit.Artifact (CompiledCircuit)
import Cortex.Wire.Circuit.Lowering
  ( CircuitLoweringError
  , CircuitPulseBinder
  , CircuitPulseConfig
  , lowerCompiledCircuitToSomeStagePlan
  )

import Platform.DurableTask.Types (RunOutcome)

-- | Why a compiled circuit could not be run through this entrypoint.
data CircuitRunError
  = -- | Lowering the compiled circuit to a stage plan failed.
    CircuitRunLoweringError CircuitLoweringError
  | {- | The lowered plan carries latent conditions with no covering executable
    stage — a deferred control form this executor cannot run. Carries the
    anchor node id of each uncovered condition. With the current compiler this
    never occurs (every @select(...)@ condition is embedded as a runnable
    stage); it guards the public entrypoint against future deferred forms.
    -}
    CircuitRunUnsupportedLatentConditions [NodeId]
  deriving stock (Eq, Show)

{- | Reject a lowered plan this entrypoint cannot execute.

Committed-variant @select(...)@ embeds each condition as a runnable stage in the
plan definitions, so the parallel latent-condition encoding is redundant for
execution: every latent condition's anchor is also an embedded stage. A latent
condition whose anchor has no embedded stage is a genuinely deferred form, which
this executor cannot run; surface it loudly instead of dropping it silently.
-}
ensureRunnable :: SomeStagePlan -> Either CircuitRunError SomeStagePlan
ensureRunnable plan@(SomeStagePlan stagePlan latentConditions) =
  case uncoveredConditions (Map.keysSet (spDefinitions stagePlan)) latentConditions of
    [] -> Right plan
    uncovered ->
      Left (CircuitRunUnsupportedLatentConditions uncovered)

uncoveredConditions :: Set NodeId -> [StageLatentCondition] -> [NodeId]
uncoveredConditions coveringNodes =
  concatMap uncoveredCondition
  where
    uncoveredCondition condition =
      [slcAnchorNodeId condition | Set.notMember (slcAnchorNodeId condition) coveringNodes]
        <> foldMap uncoveredBranch condition.slcBranches

    uncoveredBranch branch =
      uncoveredConditions (Map.keysSet branch.slbNodes) branch.slbNestedConditions

{- | Lower a compiled circuit to a runnable stage plan, rejecting deferred forms
this entrypoint cannot execute. Pure; a caller may validate a circuit with this
before acquiring execution resources.
-}
lowerRunnableCircuit
  :: CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> Either CircuitRunError SomeStagePlan
lowerRunnableCircuit pulseConfig binder compiledCircuit =
  first
    CircuitRunLoweringError
    (lowerCompiledCircuitToSomeStagePlan pulseConfig binder compiledCircuit)
    >>= ensureRunnable

{- | Lower and execute a compiled Wire circuit as a fresh durable run, dispatching
@select(...)@ on committed variant labels. Returns 'Left' if lowering fails or the
plan carries an unsupported latent form; otherwise the executor 'RunOutcome'.
-}
runCompiledCircuit
  :: TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError RunOutcome)
runCompiledCircuit taskContext runId task pulseConfig binder compiledCircuit =
  case lowerRunnableCircuit pulseConfig binder compiledCircuit of
    Left err -> pure (Left err)
    Right (SomeStagePlan stagePlan _latentConditions) ->
      Right <$> executeStagePlan taskContext runId task stagePlan

{- | Lower a compiled Wire circuit and resume its durable run from persisted graph
state. Re-evaluating a committed-variant selector reads the persisted label and
never re-invokes the producer effect (ADR 0062).
-}
resumeCompiledCircuit
  :: TaskContext
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> CircuitPulseConfig
  -> CircuitPulseBinder
  -> CompiledCircuit
  -> IO (Either CircuitRunError RunOutcome)
resumeCompiledCircuit taskContext runId task pulseConfig binder compiledCircuit =
  case lowerRunnableCircuit pulseConfig binder compiledCircuit of
    Left err -> pure (Left err)
    Right (SomeStagePlan stagePlan _latentConditions) ->
      Right <$> resumeStagePlan taskContext runId task stagePlan
