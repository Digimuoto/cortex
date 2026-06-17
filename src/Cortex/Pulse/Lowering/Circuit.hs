{- |
Module      : Cortex.Pulse.Lowering.Circuit
Description : Lower a realize frontier to a bound, durable stage (ADR 0059 §2/§3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The decision core of the Wire→Pulse lowering: given a realize node's collected
upstream frontier (classified by backend authority and await strategy), the fused
operation/measurement list, and the host binding pack, it

1. admits the contraction (ADR 0059 §2, 'admitFrontierContraction') — rejecting a
   mixed or non-backend frontier rather than splitting it;
2. resolves the realize executor through the binding pack, failing with the typed
   @missing runtime binding@ (the ADR 0054 invariant: compile succeeds without a
   pack; only runnable lowering fails);
3. builds the canonical fused plan (P6a) and its digest (the idempotency key).

The result is a 'LoweredRealize' the executor runs via
'Cortex.Pulse.Executor.ExternalCall.runExternalCall'. Walking the compiled-circuit
artifact to produce the inputs, and the @wire pulse run@ CLI, sit on top of this
core; this module keeps the admission/binding/plan decision pure and testable.
-}
module Cortex.Pulse.Lowering.Circuit
  ( LoweringError (..)
  , LoweredRealize (..)
  , lowerRealizeFrontier
  )
where

import Data.Text (Text)

import Cortex.Capability.BindingPack (HostBindingPack, lookupBinding)
import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy)
import Cortex.Capability.Catalog.RuntimeBindingRecord
  ( RuntimeBindingRecord (..)
  )
import Cortex.Pulse.Lowering.FusedPlan
  ( FusedMeasurement
  , FusedOp
  , FusedPlan
  , fusedPlan
  , fusedPlanDigest
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
  | -- | No host binding pack resolves the realize executor (ADR 0054).
    LoweringMissingRuntimeBinding !WireExecutorId
  deriving stock (Eq, Show)

data LoweredRealize = LoweredRealize
  { lrBinding :: !RuntimeBindingRecord
  , lrAwaitStrategy :: !AwaitStrategy
  , lrFusedPlan :: !FusedPlan
  , lrIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show)

{- | Lower a realize node's collected frontier to a bound, durable stage. The
collected nodes are classified by @(authority, await strategy)@ (a non-backend node
classifies as @Nothing@); ops/measurements are the fused sub-plan in topological
order.
-}
lowerRealizeFrontier
  :: HostBindingPack
  -> WireExecutorId
  -> [CollectedNode Text WireExecutorId AwaitStrategy]
  -> [FusedOp]
  -> [FusedMeasurement]
  -> Either LoweringError LoweredRealize
lowerRealizeFrontier pack realizeId collected ops measurements = do
  either (Left . LoweringInadmissibleFrontier) Right (admitFrontierContraction collected)
  binding <-
    maybe (Left (LoweringMissingRuntimeBinding realizeId)) Right (lookupBinding realizeId pack)
  let plan = fusedPlan ops measurements
  Right
    LoweredRealize
      { lrBinding = binding
      , lrAwaitStrategy = rbrAcceptedAwaitStrategy binding
      , lrFusedPlan = plan
      , lrIdempotencyKey = fusedPlanDigest plan
      }
