{- |
Module      : Cortex.Pulse.Lowering.Circuit
Description : Lower a collected external-call frontier to a bound, durable stage.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The decision core of the Wire→Pulse lowering: given a collect node's upstream
frontier (classified by backend authority and await strategy), the frozen
external-call payload steps/outputs, and the host binding pack, it

1. admits the contraction (ADR 0059 §2, 'admitFrontierContraction') — rejecting a
   mixed or non-backend frontier rather than splitting it;
2. resolves the collecting executor through the binding pack, failing with the typed
   @missing runtime binding@ (the ADR 0054 invariant: compile succeeds without a
   pack; only runnable lowering fails);
3. builds the canonical external-call payload and its digest (the idempotency key).

The result is a 'LoweredExternalCall' the executor runs via
'Cortex.Pulse.Executor.ExternalCall.runExternalCall'. Walking the compiled-circuit
artifact to produce the inputs, and the @wire pulse run@ CLI, sit on top of this
core; this module keeps the admission/binding/plan decision pure and testable.
-}
module Cortex.Pulse.Lowering.Circuit
  ( LoweringError (..)
  , LoweredExternalCall (..)
  , lowerExternalCallFrontier
  )
where

import Data.Text (Text)

import Cortex.Capability.BindingPack (HostBindingPack, lookupBinding)
import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy)
import Cortex.Capability.Catalog.RuntimeBindingRecord
  ( RuntimeBindingRecord (..)
  )
import Cortex.Pulse.Lowering.ExternalCallPayload
  ( ExternalCallOutput
  , ExternalCallPayload
  , ExternalCallStep
  , externalCallPayload
  , externalCallPayloadDigest
  )
import Cortex.Pulse.Rewrite.Contract
  ( CollectedNode
  , FrontierAdmissionError
  , admitFrontierContraction
  )
import Cortex.Wire.Executor (WireExecutorId)

data LoweringError
  = -- | The collected frontier is inadmissible (ADR 0059 §2).
    LoweringInadmissibleFrontier !(FrontierAdmissionError Text)
  | -- | No host binding pack resolves the collecting executor (ADR 0054).
    LoweringMissingRuntimeBinding !WireExecutorId
  deriving stock (Eq, Show)

data LoweredExternalCall = LoweredExternalCall
  { lrBinding :: !RuntimeBindingRecord
  , lrAwaitStrategy :: !AwaitStrategy
  , lrPayload :: !ExternalCallPayload
  , lrIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show)

{- | Lower a collected external-call frontier to a bound, durable stage. The
collected nodes are classified by @(authority, await strategy)@ (a non-backend node
classifies as @Nothing@); steps/outputs are the frozen payload in admitted order.
-}
lowerExternalCallFrontier
  :: HostBindingPack
  -> WireExecutorId
  -> [CollectedNode Text WireExecutorId AwaitStrategy]
  -> [ExternalCallStep]
  -> [ExternalCallOutput]
  -> Either LoweringError LoweredExternalCall
lowerExternalCallFrontier pack collectId collected steps outputs = do
  either (Left . LoweringInadmissibleFrontier) Right (admitFrontierContraction collected)
  binding <-
    maybe (Left (LoweringMissingRuntimeBinding collectId)) Right (lookupBinding collectId pack)
  let payload = externalCallPayload steps outputs
  Right
    LoweredExternalCall
      { lrBinding = binding
      , lrAwaitStrategy = rbrAcceptedAwaitStrategy binding
      , lrPayload = payload
      , lrIdempotencyKey = externalCallPayloadDigest payload
      }
