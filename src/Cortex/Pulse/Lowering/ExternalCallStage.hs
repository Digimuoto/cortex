{- |
Module      : Cortex.Pulse.Lowering.ExternalCallStage
Description : Bind an external-call driver into a durable Pulse stage (ADR 0059 §3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The generic binder that turns a host 'ExternalCallDriver' plus a durable
'AttemptStore' and the ADR 0053 runtime binding record into a runnable
'StageDefinition'. The bound action derives the durable attempt key from the
runtime stage context (run id, node id) plus the binding id and frontier id,
dispatches the submit/park/resume protocol under the binding's accepted await
strategy, and maps the outcome onto a Pulse @StageResult@:

* completed → 'StageComplete' with outputs wrapped through the canonical Wire
  output-envelope path (duplicate output labels are a typed failure, since a naive
  @Map@ would silently drop them);
* suspended → 'StageSuspend' on the reserved external-call wake;
* failed → a typed 'StageFail' (ADR 0026 closure), not a generic exception.
-}
module Cortex.Pulse.Lowering.ExternalCallStage
  ( bindExternalCallStage
  )
where

import Data.Aeson (Value)
import Data.List (group, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Capability.Catalog.RuntimeBindingRecord (RuntimeBindingRecord (..))
import Cortex.Pulse.Executor.ExternalCall
  ( AttemptStore
  , ExternalCallDriver
  , ExternalCallOutcome (..)
  , runExternalCall
  )
import Cortex.Pulse.Memory.Types (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageContext (..)
  , StageDefinition (..)
  , StageReplaySafety (..)
  , StageResult (..)
  , stageActionId
  , stageTemplateId
  )
import Cortex.Pulse.Query.ExternalCall (ExternalCallAttemptKey (..))
import Cortex.Pulse.Signal (SignalName (..))
import Cortex.Wire.AST (WirePorts)
import Cortex.Wire.Contract (WireContractRegistry)
import Cortex.Wire.Runtime (wrapWireStageOutputs)

{- | Bind a driver + store + runtime binding record into a durable external-call
stage. @frontierId@ is the canonical frontier identity (the payload digest) and
@frozenPayload@ the canonical external-call payload; both come from
'Cortex.Pulse.Lowering.Circuit.lowerExternalCallFrontier'. The collect node id sets
the stage identity and matches the runtime 'scNodeId' the attempt key is derived
from.
-}
bindExternalCallStage
  :: ExternalCallDriver IO
  -> AttemptStore IO
  -> RuntimeBindingRecord
  -> NodeId
  -- ^ the collect node / stage id
  -> Text
  -- ^ frontier id (canonical payload digest)
  -> Value
  -- ^ frozen external-call payload
  -> WirePorts
  -> Maybe WireContractRegistry
  -> StageDefinition NodeId
bindExternalCallStage driver store binding collectNode frontierId frozenPayload ports registry =
  StageDefinition
    { sdStageId = collectNode
    , sdTemplateId = stageTemplateId collectNode
    , sdActionId = stageActionId collectNode
    , sdReplaySafety = SafeToReplay
    , -- Crash-safe: reserve is idempotent on the key, and resume re-fetches
      -- idempotently rather than re-running an effect against the live graph.
      sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , -- Provider non-terminality is handled by the protocol's re-suspend, not by
      -- stage retry, so no retry policy is imposed here.
      sdRetryPolicy = Nothing
    , sdAction = action
    , sdMemoryStrategy = defaultMemoryStrategy
    }
  where
    action ctx = do
      let key =
            ExternalCallAttemptKey
              { ecaRunId = scRunId ctx
              , ecaNodeId = unNodeId (scNodeId ctx)
              , ecaRuntimeBindingId = rbrBindingId binding
              , ecaFrontierId = frontierId
              }
      outcome <- runExternalCall (rbrAcceptedAwaitStrategy binding) driver store key frozenPayload
      pure $ case outcome of
        ExternalCallSuspended signalName -> StageSuspend (SignalName signalName)
        ExternalCallFailed reason -> StageFail "external_call_failure" reason
        ExternalCallCompleted outputs ->
          case dedupedOutputs outputs of
            Left invalid -> StageFail "external_call_output_invalid" invalid
            Right outputMap ->
              case wrapWireStageOutputs registry (scNodeId ctx) (scRunId ctx) ports outputMap of
                Left wrapErr -> StageFail "external_call_output_invalid" wrapErr
                Right wrapped -> StageComplete wrapped

{- | Reject duplicate output labels before building the output map: a naive
@Map.fromList@ would silently drop the earlier value of a duplicated label.
-}
dedupedOutputs :: [(Text, Value)] -> Either Text (Map.Map Text Value)
dedupedOutputs outputs =
  case duplicates of
    [] -> Right (Map.fromList outputs)
    dups -> Left ("duplicate external-call output label(s): " <> T.intercalate ", " dups)
  where
    labels = fmap fst outputs
    -- Sort groups equal labels together; a group of two or more is a duplicate, and
    -- one head per group lists each duplicated label exactly once.
    duplicates = [label | label : _ : _ <- group (sort labels)]
