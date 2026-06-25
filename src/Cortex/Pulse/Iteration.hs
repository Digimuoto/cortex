{- |
Module      : Cortex.Pulse.Iteration
Description : Pulse runtime support for runtime-bounded iteration (certified self-append).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pure decision core for ADR 0055 runtime-bounded iteration. A finite kernel is
repeated by admitting a fresh @AppendAfter@ instance after the previous
iteration's loop-carried continuation node, under a frontier-shape witness and a
finite iteration budget that is separate from rewrite gas. This module is total
and authority-free: it builds the next self-append step, enforces the v1
single-anchor frontier law, admits/clamps the requested runtime bound, folds
emitted output, and names the typed loop outcomes. The durable executor consumes
these decisions; no IO or persistence lives here.
-}
module Cortex.Pulse.Iteration
  ( -- * Frontier-shape witness (v1: typed, compared not parsed)
    FrontierWitnessAlgorithm (..)
  , FrontierStateRole (..)
  , FrontierShapeWitness (..)
  , KernelBoundary (..)
  , LoopKernelWitnessAlgorithm (..)
  , LoopKernelWitness (..)
  , FrontierShapeError (..)
  , checkSelfAppendStep
  , validateKernelLocalIds
  , kernelWitnessForLocalSpec

    -- * Loop policy
  , LoopPolicy (..)
  , IterationExhaustionPolicy (..)
  , EmittedAggregationPolicy (..)
  , LoopRewriteInteraction (..)
  , LoopCancellationPoint (..)

    -- * Runtime bound admission
  , RequestedBound (..)
  , EffectiveBound (..)
  , LoopRegistration (..)
  , BoundRejection (..)
  , admitRuntimeBound
  , loopRegistrationFromRequestedBound
  , loopRegistrationAtPolicyCap

    -- * Loop control carrier
  , AggregationState (..)
  , LoopControl (..)
  , initLoopControl
  , stepIterationBudget
  , loopControlCompletedIterations
  , aggregateEmitted
  , advanceLoopControlForAppend
  , exhaustLoopControl
  , loopProducerMatchesPolicy

    -- * Typed outcomes
  , LoopOutcome (..)
  , LoopTerminalReason (..)
  , budgetExhaustionOutcome

    -- * Self-append step
  , LoopStepDecision (..)
  , LoopStepWitness (..)
  , LoopStopReason (..)
  , iterationNamespaceSeed
  , planLoopStep

    -- * Witnessed-step authorization (security gate for gas-neutral admission)
  , WitnessedStepViolation (..)
  , renderWitnessedStepViolation
  , authorizeWitnessedStep
  , authorizeWitnessedStepWithControl
  , checkKernelSizeBound
  )
where

import Control.Monad (unless, when)
import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Text.Read (readMaybe)

import Cortex.Algebra.Graph (relEdges, relVertices)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite
  ( ExpectedActual (..)
  , GraphRewrite (..)
  , RewriteCost (..)
  , SubgraphSpec (..)
  , namespaceSubgraph
  )

-- ---------------------------------------------------------------------------
-- Frontier-shape witness
-- ---------------------------------------------------------------------------

{- | Declared algorithm/version of a 'FrontierShapeWitness'. Pulse never parses
Wire port contracts in v1; the witness is produced by the Wire/lowering layer
from the ADR 0047 typed @(role, label, contract)@ frontier, and Pulse only
compares it. The algorithm tag carries the generator's provenance/version so a
future witness scheme is a distinct, non-equal value rather than a silent
collision.
-}
data FrontierWitnessAlgorithm
  = FrontierWitnessV1
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The designated loop-state role label on a kernel boundary.
newtype FrontierStateRole = FrontierStateRole {unFrontierStateRole :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

{- | A certified, typed frontier-shape witness carried by a kernel declaration.
Equality is structural over @(algorithm, digest)@. Pulse treats @fswDigest@ as
opaque: it compares it across self-append steps but never recomputes it.
-}
data FrontierShapeWitness = FrontierShapeWitness
  { fswAlgorithm :: !FrontierWitnessAlgorithm
  , fswDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | The admitted kernel boundary (ADR 0055 §Kernel boundary). The loop-carried
continuation crossing the iteration boundary is a single designated loop-state
output role; the full kernel exit surface may still be wider (emitted, guard,
terminal). Single role fields, not lists, encode the v1 single-anchor law
structurally.
-}
data KernelBoundary = KernelBoundary
  { kbWitness :: !FrontierShapeWitness
  , kbStateInRole :: !FrontierStateRole
  , kbStateOutRole :: !FrontierStateRole
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Declared algorithm/version for the certified kernel digest. The digest is
computed over the kernel's normalized local topology, frontier ids, and
serializable stage-definition payloads. Pulse compares it but does not interpret
definition semantics.
-}
data LoopKernelWitnessAlgorithm
  = LoopKernelWitnessV1
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Opaque digest for the finite loop kernel authorized for gas-neutral append.
data LoopKernelWitness = LoopKernelWitness
  { lkwAlgorithm :: !LoopKernelWitnessAlgorithm
  , lkwDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Why a proposed self-append step violates the v1 frontier-shape law.
data FrontierShapeError
  = -- | @exit_frontier(i)@ witness /= the kernel-declaration witness.
    FrontierWitnessMismatch !(ExpectedActual FrontierShapeWitness)
  | {- | The loop-carried continuation is produced by more than one exit node.
    v1 admits only a single composite continuation anchor (ADR 0055).
    -}
    FrontierMultiNodeContinuation ![NodeId]
  | -- | The next @AppendAfter@ does not anchor on the designated loop-state node.
    FrontierAnchorMismatch !(ExpectedActual NodeId)
  | {- | A kernel-template local id is not a single bounded namespace segment
    (empty, contains the @:@ delimiter, or exceeds @lpMaxSegmentLen@). Such ids
    would break the flat @loop_root:iter_<i>:<local>@ discipline once namespaced.
    -}
    FrontierInvalidKernelLocalIds ![NodeId]
  deriving stock (Eq, Show, Generic)

{- | The v1 self-append admission law. Given the kernel boundary, the observed
exit-frontier witness of iteration @i@, the designated loop-state exit producer
set, and the node the next @AppendAfter@ will anchor on, check:

  1. witness equality across the step (shape, not node identity);
  2. the designated loop-state exit set has cardinality exactly one;
  3. the next append anchors on that single node.

The @[NodeId]@ argument is the /designated loop-state/ exit set only — the full
kernel exit surface (emitted/guard/terminal) is not subject to this cardinality
check.
-}
checkSelfAppendStep
  :: KernelBoundary
  -> FrontierShapeWitness
  -> [NodeId]
  -> NodeId
  -> Either FrontierShapeError ()
checkSelfAppendStep boundary observed loopStateExits anchor = do
  unless (kbWitness boundary == observed) $
    Left (FrontierWitnessMismatch (ExpectedActual (kbWitness boundary) observed))
  case loopStateExits of
    [single]
      | single == anchor -> Right ()
      | otherwise -> Left (FrontierAnchorMismatch (ExpectedActual single anchor))
    _ -> Left (FrontierMultiNodeContinuation loopStateExits)

{- | Enforce the flat-namespace discipline on a raw kernel template before it is
namespaced under the @loop_root:iter_<i>@ seed: every template node id must be a
single, non-empty namespace segment (no @:@ delimiter) within @maxSegmentLen@.
With this invariant, namespacing produces exactly @loop_root:iter_<i>:<local>@
ids — flat, under-seed, and bounded — closing the O(n)-nesting and oversized-id
footguns. (The downstream 'Cortex.Pulse.Rewrite.planGraphRewriteNamespaced'
checks only freshness, trusting this producer-side discipline.)
-}
validateKernelLocalIds :: Natural -> SubgraphSpec NodeId def -> Either FrontierShapeError ()
validateKernelLocalIds maxSegmentLen spec =
  let ids = Map.keys (sgsDefinitions spec)
      bad = filter (invalidLocalSegment maxSegmentLen) ids
   in if null bad then Right () else Left (FrontierInvalidKernelLocalIds bad)

invalidLocalSegment :: Natural -> NodeId -> Bool
invalidLocalSegment maxSegmentLen (NodeId segment) =
  T.null segment
    || T.elem ':' segment
    || fromIntegral (T.length segment) > maxSegmentLen

data CanonicalLoopKernel def = CanonicalLoopKernel
  { clkTopologyNodes :: ![Text]
  , clkTopologyEdges :: ![(Text, Text)]
  , clkDefinitions :: ![(Text, def)]
  , clkEntryNodes :: ![Text]
  , clkExitNodes :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

{- | Compute the policy-side digest for an un-namespaced kernel template. The
caller should first run 'validateKernelLocalIds' with the policy segment bound;
this function only canonicalizes and hashes.
-}
kernelWitnessForLocalSpec :: ToJSON def => SubgraphSpec NodeId def -> LoopKernelWitness
kernelWitnessForLocalSpec =
  hashCanonicalKernel . canonicalKernelSpec unNodeId

hashCanonicalKernel :: ToJSON def => CanonicalLoopKernel def -> LoopKernelWitness
hashCanonicalKernel kernel =
  LoopKernelWitness
    { lkwAlgorithm = LoopKernelWitnessV1
    , lkwDigest = T.pack (show (hashlazy @SHA256 (Aeson.encode kernel)))
    }

canonicalKernelSpec
  :: (NodeId -> Text)
  -> SubgraphSpec NodeId def
  -> CanonicalLoopKernel def
canonicalKernelSpec render spec =
  CanonicalLoopKernel
    { clkTopologyNodes = List.sort (render <$> Set.toList (relVertices (sgsTopology spec)))
    , clkTopologyEdges =
        List.sort
          [ (render fromNode, render toNode)
          | (fromNode, toNode) <- Set.toList (relEdges (sgsTopology spec))
          ]
    , clkDefinitions =
        List.sortOn
          fst
          [ (render nodeId, def)
          | (nodeId, def) <- Map.toList (sgsDefinitions spec)
          ]
    , clkEntryNodes = render <$> sgsEntryNodes spec
    , clkExitNodes = render <$> sgsExitNodes spec
    }

canonicalKernelSpecEither
  :: (NodeId -> Either WitnessedStepViolation Text)
  -> SubgraphSpec NodeId def
  -> Either WitnessedStepViolation (CanonicalLoopKernel def)
canonicalKernelSpecEither render spec = do
  topologyNodes <- traverse render (Set.toList (relVertices (sgsTopology spec)))
  topologyEdges <-
    traverse
      ( \(fromNode, toNode) -> do
          fromLocal <- render fromNode
          toLocal <- render toNode
          pure (fromLocal, toLocal)
      )
      (Set.toList (relEdges (sgsTopology spec)))
  definitions <-
    traverse
      ( \(nodeId, def) -> do
          local <- render nodeId
          pure (local, def)
      )
      (Map.toList (sgsDefinitions spec))
  entryNodes <- traverse render (sgsEntryNodes spec)
  exitNodes <- traverse render (sgsExitNodes spec)
  pure
    CanonicalLoopKernel
      { clkTopologyNodes = List.sort topologyNodes
      , clkTopologyEdges = List.sort topologyEdges
      , clkDefinitions = List.sortOn fst definitions
      , clkEntryNodes = entryNodes
      , clkExitNodes = exitNodes
      }

-- ---------------------------------------------------------------------------
-- Loop policy
-- ---------------------------------------------------------------------------

{- | Behavior when the iteration budget is exhausted with work remaining
(ADR 0055 §Completion). Budget exhaustion is never silent success. The default
is failure unless the node contract declares a partial-result shape.
-}
data IterationExhaustionPolicy
  = IterationExhaustionFail
  | IterationExhaustionPartial
  | IterationExhaustionFallback
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How per-iteration emitted output is folded across iterations.
data EmittedAggregationPolicy
  = AggregateAccumulate
  | AggregateReduceLast
  | AggregateDiscard
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Whether the kernel body may propose open topology. v1 admits only
rewrite-closed kernels for the self-append loop; an open-body kernel is
inadmissible until the shared/per-step gas law is explicit (ADR 0055/0056).
-}
data LoopRewriteInteraction
  = LoopKernelRewriteClosed
  | LoopKernelRewriteOpenRejected
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Points at which a runtime-bounded loop checks cancellation.
data LoopCancellationPoint
  = CancelBetweenIterations
  | CancelBeforeIrreversibleAction
  | CancelAtParkedAwait
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Pulse-owned static policy carrier for a runtime-bounded loop. The policy
cap is a compile/runtime envelope; each run also admits an 'EffectiveBound' and
tracks a mutable 'LoopControl'. Witnessed self-append admission must consult all
three, not this static policy alone.
-}
data LoopPolicy = LoopPolicy
  { lpMaxIterations :: !Natural
  , lpExhaustion :: !IterationExhaustionPolicy
  , lpCheckpointCadence :: !Natural
  , lpCancellationPoints :: !(Set LoopCancellationPoint)
  , lpNamespaceRoot :: !NodeId
  , lpMaxSegmentLen :: !Natural
  , lpMaxKernelNodes :: !Natural
  {- ^ Per-append structural envelope: a witnessed append admits gas-neutral, so
  its size must be bounded here or one append could fan out an unbounded
  subgraph for free. Total gas-free growth is bounded by
  @lpMaxIterations * lpMaxKernelNodes@ (and edges/depth).
  -}
  , lpMaxKernelEdges :: !Natural
  , lpMaxKernelDepth :: !Natural
  , lpAggregation :: !EmittedAggregationPolicy
  , lpMaxAggregatedItems :: !(Maybe Natural)
  , lpRewriteInteraction :: !LoopRewriteInteraction
  , lpKernelBoundary :: !KernelBoundary
  , lpKernelWitness :: !LoopKernelWitness
  , lpPolicyVersion :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Runtime bound admission
-- ---------------------------------------------------------------------------

-- | A runtime-proposed iteration bound (already decoded to a 'Natural').
newtype RequestedBound = RequestedBound {unRequestedBound :: Natural}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | The admitted effective bound: @min request cap@.
newtype EffectiveBound = EffectiveBound {unEffectiveBound :: Natural}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

{- | A loop kernel registered for witnessed self-append in a concrete run. The
static policy says what shape is certifiable; the effective bound is the
per-run admitted maximum body-execution count after request validation/clamping.
-}
data LoopRegistration = LoopRegistration
  { lrPolicy :: !LoopPolicy
  , lrEffectiveBound :: !EffectiveBound
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Why a requested runtime bound is rejected before the first body execution.
data BoundRejection
  = -- | The validated, clamped bound is zero; a loop must run at least once.
    BoundZeroNotAllowed
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Admit a runtime-proposed bound against policy. The admitted effective bound
is the minimum of the validated request and the configured policy cap. A zero
effective bound is rejected: a loop must execute its body at least once.
-}
admitRuntimeBound :: LoopPolicy -> RequestedBound -> Either BoundRejection EffectiveBound
admitRuntimeBound policy (RequestedBound req) =
  let eff = min req (lpMaxIterations policy)
   in if eff == 0 then Left BoundZeroNotAllowed else Right (EffectiveBound eff)

loopRegistrationFromRequestedBound
  :: LoopPolicy -> RequestedBound -> Either BoundRejection LoopRegistration
loopRegistrationFromRequestedBound policy requested =
  LoopRegistration policy <$> admitRuntimeBound policy requested

loopRegistrationAtPolicyCap :: LoopPolicy -> Either BoundRejection LoopRegistration
loopRegistrationAtPolicyCap policy =
  loopRegistrationFromRequestedBound policy (RequestedBound (lpMaxIterations policy))

-- ---------------------------------------------------------------------------
-- Loop control carrier
-- ---------------------------------------------------------------------------

{- | The emitted-output aggregation accumulator. The fold is order-stable so a
snapshot re-fold of the same ordered prefix re-derives the same value
(ADR 0055 §snapshots).
-}
data AggregationState = AggregationState
  { asItems :: ![Value]
  , asCount :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | The minimal typed control side-state for a runtime-bounded loop. This is
authoritative control state, not graph-derived loop-carried values; it rides in
the durable checkpoint payload. The iteration index is intentionally NOT stored
here — it is derived from the count of witnessed loop-kernel append rewrites
materialized through the watermark, and reconciled on resume.
-}
data LoopControl = LoopControl
  { lcPolicyVersion :: !Int
  , lcEffectiveBound :: !EffectiveBound
  , lcRemainingIterations :: !Natural
  {- ^ Remaining self-append steps after the seed @iter_0@ body has consumed one
  body-execution slot.
  -}
  , lcAggregation :: !AggregationState
  , lcNamespaceRoot :: !NodeId
  , lcOutcome :: !(Maybe LoopOutcome)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Build the initial loop control from policy and the admitted effective bound.
@iter_0@ is the seed body execution, so the remaining counter tracks only
post-seed self-appends.
-}
initLoopControl :: LoopPolicy -> EffectiveBound -> LoopControl
initLoopControl policy effective@(EffectiveBound n) =
  LoopControl
    { lcPolicyVersion = lpPolicyVersion policy
    , lcEffectiveBound = effective
    , lcRemainingIterations = monus n 1
    , lcAggregation = AggregationState {asItems = [], asCount = 0}
    , lcNamespaceRoot = lpNamespaceRoot policy
    , lcOutcome = Nothing
    }
  where
    monus a b = if a >= b then a - b else 0

{- | Record one admitted self-append by decrementing the remaining append budget.
Subtraction saturates at zero so a 'Natural' never underflows; the precondition
is that a preceding 'planLoopStep' returned 'LoopContinue', which only happens
while the budget is positive.
-}
stepIterationBudget :: LoopControl -> LoopControl
stepIterationBudget ctrl =
  ctrl {lcRemainingIterations = monus (lcRemainingIterations ctrl) 1}
  where
    monus a b = if a >= b then a - b else 0

{- | Count body executions represented by the current control state. @iter_0@
is the seed execution, so a freshly initialized control for bound @N@ already
represents one body execution and expects the first append to materialize
@iter_1@.
-}
loopControlCompletedIterations :: LoopControl -> Natural
loopControlCompletedIterations ctrl =
  let EffectiveBound effective = lcEffectiveBound ctrl
      remaining = lcRemainingIterations ctrl
   in if effective >= remaining then effective - remaining else 0

{- | Fold one optional emitted value into the aggregation state per policy.
@asCount@ always advances (it meters how many emissions were seen); @asItems@
accumulates only up to @lpMaxAggregatedItems@ so iteration count alone does not
bound accumulated payload size.
-}
aggregateEmitted :: LoopPolicy -> AggregationState -> Maybe Value -> AggregationState
aggregateEmitted policy st memitted = case memitted of
  Nothing -> st
  Just v -> case lpAggregation policy of
    AggregateDiscard -> st {asCount = asCount st + 1}
    AggregateReduceLast -> st {asItems = [v], asCount = asCount st + 1}
    AggregateAccumulate ->
      let withinCap = maybe True (asCount st <) (lpMaxAggregatedItems policy)
       in if withinCap
            then st {asItems = asItems st <> [v], asCount = asCount st + 1}
            else st {asCount = asCount st + 1}

-- | Fold the current iteration's emitted value and consume one append slot.
advanceLoopControlForAppend :: LoopPolicy -> LoopControl -> Maybe Value -> LoopControl
advanceLoopControlForAppend policy control emitted =
  stepIterationBudget
    control
      { lcAggregation = aggregateEmitted policy (lcAggregation control) emitted
      }

{- | Finalize the run-local loop carrier when the body asks for another
iteration after the admitted bound has been exhausted. The graph-carried output
is still folded before the typed outcome is recorded.
-}
exhaustLoopControl :: LoopPolicy -> LoopControl -> Value -> LoopControl
exhaustLoopControl policy control lastOutput =
  let aggregation = aggregateEmitted policy (lcAggregation control) (Just lastOutput)
      completed = loopControlCompletedIterations control
   in control
        { lcAggregation = aggregation
        , lcOutcome = Just (budgetExhaustionOutcome policy completed lastOutput)
        }

-- ---------------------------------------------------------------------------
-- Typed outcomes
-- ---------------------------------------------------------------------------

-- | Why a loop completed cleanly (as opposed to stopping on budget exhaustion).
data LoopTerminalReason
  = TerminatedByGuard
  | TerminatedByBoundReached
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | The typed terminal outcome of a runtime-bounded loop. Budget exhaustion,
cancellation, partial completion, and fallback are each distinct from ordinary
success so downstream consumers can tell "finished" from "stopped safely".
-}
data LoopOutcome
  = LoopCompleted !LoopTerminalReason !Value
  | LoopBudgetExhausted !Natural
  | LoopCancelled !LoopCancellationPoint
  | LoopPartial !Value !Natural
  | LoopFallback !Value
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Map an iteration-budget exhaustion to the typed outcome chosen by policy.
The executor supplies the count of completed iterations and the last body output
(used for partial/fallback shapes).
-}
budgetExhaustionOutcome :: LoopPolicy -> Natural -> Value -> LoopOutcome
budgetExhaustionOutcome policy completed lastOutput = case lpExhaustion policy of
  IterationExhaustionFail -> LoopBudgetExhausted completed
  IterationExhaustionPartial -> LoopPartial lastOutput completed
  IterationExhaustionFallback -> LoopFallback lastOutput

{- | True when a materialized producer node belongs to a loop policy namespace.
This is intentionally weaker than witnessed-step authorization: it identifies
which loop instance owns a producer, while the full authorization gate still
checks the canonical next index, frontier witness, kernel digest, and bound.
-}
loopProducerMatchesPolicy :: LoopPolicy -> NodeId -> Bool
loopProducerMatchesPolicy policy (NodeId producer) =
  case T.stripPrefix (unNodeId (lpNamespaceRoot policy) <> ":iter_") producer of
    Nothing -> False
    Just rest ->
      case T.breakOn ":" rest of
        (idxText, segWithDelimiter)
          | Just segment <- T.stripPrefix ":" segWithDelimiter ->
              isJust (canonicalNatural idxText)
                && validSegment (lpMaxSegmentLen policy) segment
        _ -> False

-- ---------------------------------------------------------------------------
-- Self-append step
-- ---------------------------------------------------------------------------

-- | Why 'planLoopStep' declined to emit a next append step.
data LoopStopReason
  = -- | The iteration budget is exhausted after @completed@ iterations.
    StoppedBudgetExhausted !Natural
  deriving stock (Eq, Show, Generic)

-- | The decision for the next loop step.
data LoopStepDecision def
  = -- | Continue: the next @AppendAfter@ and the witness the step must preserve.
    LoopContinue !(GraphRewrite NodeId def) !FrontierShapeWitness
  | -- | Stop without appending; the executor maps the reason to a 'LoopOutcome'.
    LoopStop !LoopStopReason
  deriving stock (Show, Generic)

{- | Live frontier evidence for a witnessed loop step. The witness token is
produced by the kernel/lowering layer, while @lswLoopStateExits@ is the
designated loop-state exit producer set, not the full emitted/guard/terminal
exit surface.
-}
data LoopStepWitness = LoopStepWitness
  { lswFrontierWitness :: !FrontierShapeWitness
  , lswLoopStateExits :: ![NodeId]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | The deterministic, flat per-iteration namespace seed: @loop_root:iter_<i>@.
This is the namespace /parent/ for a freshly admitted kernel instance; it is
decoupled from the topological anchor so anchoring on the prior iteration's
materialized node never feeds that id back in as a prefix (no O(N) nesting).
-}
iterationNamespaceSeed :: NodeId -> Natural -> NodeId
iterationNamespaceSeed (NodeId root) i = NodeId (root <> ":iter_" <> T.pack (show i))

{- | Plan the next self-append step. Given the current iteration index @i@, the
remaining iteration budget, the prior iteration's designated loop-state output
node (the anchor), the observed exit witness, the designated loop-state exit
producer set, and the raw kernel template:

  * if the budget is exhausted, stop (the executor maps to a typed outcome);
  * otherwise enforce the v1 frontier law via 'checkSelfAppendStep', then build
    an @AppendAfter@ on the anchor whose kernel instance is namespaced flat under
    @loop_root:iter_<i+1>@.

The kernel template's local ids are namespaced here under the flat seed, so the
caller must admit this rewrite through a path that does /not/ re-namespace under
the anchor (which would nest and be rejected by namespace discipline).
-}
planLoopStep
  :: LoopPolicy
  -> Natural
  -> Natural
  -> NodeId
  -> FrontierShapeWitness
  -> [NodeId]
  -> SubgraphSpec NodeId def
  -> Either FrontierShapeError (LoopStepDecision def)
planLoopStep policy i remaining anchor exitWitness loopStateExits kernelSpec
  | remaining == 0 = Right (LoopStop (StoppedBudgetExhausted i))
  | otherwise = do
      checkSelfAppendStep (lpKernelBoundary policy) exitWitness loopStateExits anchor
      validateKernelLocalIds (lpMaxSegmentLen policy) kernelSpec
      let seed = iterationNamespaceSeed (lpNamespaceRoot policy) (i + 1)
          spec' = namespaceSubgraph seed kernelSpec
      pure (LoopContinue (AppendAfter anchor spec') (kbWitness (lpKernelBoundary policy)))

-- ---------------------------------------------------------------------------
-- Witnessed-step authorization (security gate for gas-neutral admission)
-- ---------------------------------------------------------------------------

{- | Why a proposed witnessed (gas-neutral) self-append step is rejected. Because
'Cortex.Pulse.Plan.StageLoopStep' carries a plain, caller-supplied rewrite, the
executor must verify the step is a genuine, bounded, in-namespace self-append
before admitting it gas-neutral — otherwise an arbitrary stage could bypass
rewrite gas. The same gate runs on live admission and on replay.
-}
data WitnessedStepViolation
  = -- | The rewrite is not an @AppendAfter@ (e.g. an @ExpandNode@).
    StepNotAppendAfter
  | {- | The append anchors on a node other than the genuine producer: a stage may
    only append after itself.
    -}
    StepAnchorMismatch !(ExpectedActual NodeId)
  | {- | The per-append subgraph exceeds the policy size envelope; one gas-neutral
    append must not fan out an unbounded subgraph.
    -}
    StepKernelTooLarge !RewriteCost
  | {- | The producer node id is not @<root>:iter_<i>:<seg>@ under the policy
    namespace root, so its canonical next iteration cannot be derived.
    -}
    StepProducerNotInNamespace !NodeId
  | -- | The producer's next iteration index would reach or exceed @lpMaxIterations@.
    StepIterationCapExceeded !Natural
  | {- | An inserted node id is not exactly @<root>:iter_<i+1>:<seg>@ — the
    producer's canonical next iteration — with @<seg>@ one bounded, @:@-free
    segment. Catches out-of-namespace grafts, non-canonical or aliased indices
    (e.g. @iter_01@), index skipping/reuse, recursive nesting, and oversized ids.
    -}
    StepNamespaceViolation ![NodeId]
  | {- | The live loop-state frontier witness does not satisfy the v1
     single-anchor self-append law for the authorizing policy.
    -}
    StepFrontierViolation !FrontierShapeError
  | {- | The actual appended kernel, normalized back to local ids, does not match
     the policy-certified finite kernel digest.
    -}
    StepKernelWitnessMismatch !(ExpectedActual LoopKernelWitness)
  | {- | The run-local loop control does not belong to the registered policy/root
     for this kernel, or carries an impossible effective bound.
    -}
    StepLoopControlMismatch !Text
  | {- | The producer's canonical next iteration does not match the next body
     index implied by the run-local control.
    -}
    StepIterationIndexMismatch !(ExpectedActual Natural)
  | -- | The run-local effective bound has no remaining self-append budget.
    StepIterationBudgetExhausted !Natural
  deriving stock (Eq, Show, Generic)

renderWitnessedStepViolation :: WitnessedStepViolation -> Text
renderWitnessedStepViolation = \case
  StepNotAppendAfter -> "witnessed loop step is not an AppendAfter"
  StepAnchorMismatch ea ->
    "witnessed loop step does not self-append (expected anchor "
      <> unNodeId (eaExpected ea)
      <> ", got "
      <> unNodeId (eaActual ea)
      <> ")"
  StepKernelTooLarge _ ->
    "witnessed loop step exceeds the per-append kernel size envelope"
  StepProducerNotInNamespace (NodeId p) ->
    "witnessed loop step producer " <> p <> " is not a loop-namespace node"
  StepIterationCapExceeded n ->
    "witnessed loop step exceeds the iteration cap at iteration " <> T.pack (show n)
  StepNamespaceViolation bad ->
    "witnessed loop step inserts ids that are not the producer's canonical next iteration: "
      <> T.intercalate ", " (fmap unNodeId bad)
  StepFrontierViolation err ->
    "witnessed loop step frontier shape is not admissible: " <> T.pack (show err)
  StepKernelWitnessMismatch ea ->
    "witnessed loop step kernel does not match the certified loop kernel (expected "
      <> lkwDigest (eaExpected ea)
      <> ", got "
      <> lkwDigest (eaActual ea)
      <> ")"
  StepLoopControlMismatch reason ->
    "witnessed loop step control does not match the registered loop policy: " <> reason
  StepIterationIndexMismatch ea ->
    "witnessed loop step targets iteration "
      <> T.pack (show (eaActual ea))
      <> " but run-local control expects iteration "
      <> T.pack (show (eaExpected ea))
  StepIterationBudgetExhausted completed ->
    "witnessed loop step effective iteration budget is exhausted after "
      <> T.pack (show completed)
      <> " body executions"

{- | Static witnessed-step authorization for the shape/kernel portion of a
gas-neutral self-append. Given the authorizing policy, the GENUINE producer node
(never a node read from the rewrite), the rewrite, and its planned cost, verify
the step is a bounded self-append of the producer's CANONICAL next iteration.
Binding inserted ids to @<root>:iter_<i+1>:<seg>@ (where @i@ is the producer's
own zero-based iteration) bounds static-policy growth to
@lpMaxIterations * lpMaxKernelNodes@: @iter_0@ is the first body execution, so
appending @iter_<lpMaxIterations>@ is rejected.

Live admission and resume must call 'authorizeWitnessedStepWithControl' instead;
the static policy alone cannot enforce a lower admitted per-run effective bound.
-}
authorizeWitnessedStep
  :: ToJSON def
  => LoopPolicy
  -> NodeId
  -> LoopStepWitness
  -> GraphRewrite NodeId def
  -> RewriteCost
  -> Either WitnessedStepViolation ()
authorizeWitnessedStep policy producer witness rewrite cost = do
  spec <- requireSelfAppend producer rewrite
  firstFrontierViolation $
    checkSelfAppendStep
      (lpKernelBoundary policy)
      (lswFrontierWitness witness)
      (lswLoopStateExits witness)
      producer
  checkKernelSizeBound policy cost
  nextIdx <- producerNextIteration policy producer
  checkCanonicalInsertedIds policy nextIdx spec
  checkKernelWitness policy nextIdx spec

{- | Control-aware witnessed-step authorization for live admission and resume.
This is the gate that enforces the /per-run/ effective bound: static policy
authorization alone is insufficient because a run may admit a lower bound than
@lpMaxIterations@. On success it returns the next 'LoopControl', with one
self-append consumed.
-}
authorizeWitnessedStepWithControl
  :: ToJSON def
  => LoopPolicy
  -> LoopControl
  -> NodeId
  -> LoopStepWitness
  -> Maybe Value
  -> GraphRewrite NodeId def
  -> RewriteCost
  -> Either WitnessedStepViolation LoopControl
authorizeWitnessedStepWithControl policy control producer witness emitted rewrite cost = do
  spec <- requireSelfAppend producer rewrite
  firstFrontierViolation $
    checkSelfAppendStep
      (lpKernelBoundary policy)
      (lswFrontierWitness witness)
      (lswLoopStateExits witness)
      producer
  checkKernelSizeBound policy cost
  nextIdx <- producerNextIteration policy producer
  checkLoopControl policy control nextIdx
  checkCanonicalInsertedIds policy nextIdx spec
  checkKernelWitness policy nextIdx spec
  pure (advanceLoopControlForAppend policy control emitted)

checkLoopControl
  :: LoopPolicy -> LoopControl -> Natural -> Either WitnessedStepViolation ()
checkLoopControl policy control nextIdx = do
  when (lpCheckpointCadence policy == 0) . Left . StepLoopControlMismatch $
    "checkpoint cadence must be at least 1"
  unless
    (Set.isSubsetOf (lpCancellationPoints policy) (Set.singleton CancelBetweenIterations))
    . Left
    . StepLoopControlMismatch
    $ "v1 witnessed loop admission supports only between-iteration cancellation"
  unless (lcPolicyVersion control == lpPolicyVersion policy) . Left . StepLoopControlMismatch $
    "policy version "
      <> T.pack (show (lcPolicyVersion control))
      <> " /= registered version "
      <> T.pack (show (lpPolicyVersion policy))
  unless (lcNamespaceRoot control == lpNamespaceRoot policy) . Left . StepLoopControlMismatch $
    "namespace root "
      <> unNodeId (lcNamespaceRoot control)
      <> " /= registered root "
      <> unNodeId (lpNamespaceRoot policy)
  let EffectiveBound effective = lcEffectiveBound control
  when (effective == 0 || effective > lpMaxIterations policy) . Left . StepLoopControlMismatch $
    "effective bound "
      <> T.pack (show effective)
      <> " is outside policy cap "
      <> T.pack (show (lpMaxIterations policy))
  let expectedNext = loopControlCompletedIterations control
  unless (nextIdx == expectedNext) $
    Left (StepIterationIndexMismatch (ExpectedActual expectedNext nextIdx))
  when (lcRemainingIterations control == 0) $
    Left (StepIterationBudgetExhausted expectedNext)

firstFrontierViolation :: Either FrontierShapeError () -> Either WitnessedStepViolation ()
firstFrontierViolation =
  either (Left . StepFrontierViolation) Right

requireSelfAppend
  :: NodeId -> GraphRewrite NodeId def -> Either WitnessedStepViolation (SubgraphSpec NodeId def)
requireSelfAppend producer = \case
  AppendAfter anchor spec
    | anchor == producer -> Right spec
    | otherwise -> Left (StepAnchorMismatch (ExpectedActual producer anchor))
  ExpandNode {} -> Left StepNotAppendAfter

-- | Reject a witnessed append whose planned cost exceeds the policy size envelope.
checkKernelSizeBound :: LoopPolicy -> RewriteCost -> Either WitnessedStepViolation ()
checkKernelSizeBound policy cost
  | rcAddedNodes cost > lpMaxKernelNodes policy = Left (StepKernelTooLarge cost)
  | rcAddedEdges cost > lpMaxKernelEdges policy = Left (StepKernelTooLarge cost)
  | rcAddedDepth cost > lpMaxKernelDepth policy = Left (StepKernelTooLarge cost)
  | otherwise = Right ()

checkKernelWitness
  :: ToJSON def
  => LoopPolicy
  -> Natural
  -> SubgraphSpec NodeId def
  -> Either WitnessedStepViolation ()
checkKernelWitness policy nextIdx spec = do
  actual <- kernelWitnessForNamespacedSpec policy nextIdx spec
  unless (actual == lpKernelWitness policy) $
    Left (StepKernelWitnessMismatch (ExpectedActual (lpKernelWitness policy) actual))

kernelWitnessForNamespacedSpec
  :: ToJSON def
  => LoopPolicy
  -> Natural
  -> SubgraphSpec NodeId def
  -> Either WitnessedStepViolation LoopKernelWitness
kernelWitnessForNamespacedSpec policy nextIdx spec = do
  let prefix = unNodeId (lpNamespaceRoot policy) <> ":iter_" <> T.pack (show nextIdx) <> ":"
      localize = localSegment prefix (lpMaxSegmentLen policy)
  canonical <- canonicalKernelSpecEither localize spec
  pure (hashCanonicalKernel canonical)

localSegment :: Text -> Natural -> NodeId -> Either WitnessedStepViolation Text
localSegment prefix maxSegmentLen nodeId@(NodeId raw) =
  case T.stripPrefix prefix raw of
    Just segment | validSegment maxSegmentLen segment -> Right segment
    _ -> Left (StepNamespaceViolation [nodeId])

{- | Derive the producer's canonical next iteration index. The producer must be a
loop-namespace node @<root>:iter_<i>:<seg>@; the next index is @i + 1@. Iteration
ids are zero-based and @iter_0@ is the seed body, so @next >= lpMaxIterations@
would exceed the maximum body-execution cap and is rejected. @i@ must be a
canonical decimal so an aliased producer id cannot smuggle a different successor.
-}
producerNextIteration :: LoopPolicy -> NodeId -> Either WitnessedStepViolation Natural
producerNextIteration policy producer@(NodeId p) =
  case T.stripPrefix (unNodeId (lpNamespaceRoot policy) <> ":iter_") p of
    Nothing -> Left (StepProducerNotInNamespace producer)
    Just rest ->
      case T.breakOn ":" rest of
        (idxText, segWithDelimiter)
          | Just segment <- T.stripPrefix ":" segWithDelimiter ->
              if validSegment (lpMaxSegmentLen policy) segment
                then case canonicalNatural idxText of
                  Nothing -> Left (StepProducerNotInNamespace producer)
                  Just i ->
                    let next = i + 1
                     in if next >= lpMaxIterations policy
                          then Left (StepIterationCapExceeded next)
                          else Right next
                else Left (StepProducerNotInNamespace producer)
        _ -> Left (StepProducerNotInNamespace producer)

validSegment :: Natural -> Text -> Bool
validSegment maxSegmentLen segment =
  not (T.null segment)
    && not (T.elem ':' segment)
    && fromIntegral (T.length segment) <= maxSegmentLen

{- | Every inserted node id must be exactly @<root>:iter_<next>:<seg>@ — the
producer's canonical next iteration — with @<seg>@ one non-empty, @:@-free
segment of length @<= lpMaxSegmentLen@.
-}
checkCanonicalInsertedIds
  :: LoopPolicy -> Natural -> SubgraphSpec NodeId def -> Either WitnessedStepViolation ()
checkCanonicalInsertedIds policy next spec =
  let prefix = unNodeId (lpNamespaceRoot policy) <> ":iter_" <> T.pack (show next) <> ":"
      ids = Map.keys (sgsDefinitions spec)
      bad = filter (not . validUnderPrefix prefix (lpMaxSegmentLen policy)) ids
   in if null bad then Right () else Left (StepNamespaceViolation bad)

validUnderPrefix :: Text -> Natural -> NodeId -> Bool
validUnderPrefix prefix maxSegmentLen (NodeId nodeId) =
  case T.stripPrefix prefix nodeId of
    Just seg -> validSegment maxSegmentLen seg
    Nothing -> False

{- | Parse a canonical non-negative decimal: digits only, no leading zeros
(except @0@ itself), so @01@ does not alias @1@.
-}
canonicalNatural :: Text -> Maybe Natural
canonicalNatural t = case readMaybe (T.unpack t) :: Maybe Natural of
  Just n | t == T.pack (show n) -> Just n
  _ -> Nothing
