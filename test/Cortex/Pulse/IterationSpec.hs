{- |
Module      : Cortex.Pulse.IterationSpec
Description : Tests for Cortex.Pulse.Iteration (runtime-bounded iteration pure core).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.IterationSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Numeric.Natural (Natural)
import Test.Hspec

import Cortex.Algebra.Graph (Graph (..), edge, path, toRelation)
import Cortex.Pulse.Iteration
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite
  ( AdmissionMode (..)
  , ExpansionMode (..)
  , GraphRewrite (..)
  , PlannedRewriteDelta (..)
  , RewriteBudget (..)
  , RewriteCost (..)
  , SubgraphSpec (..)
  , admitRewriteDelta
  , admitWitnessedDelta
  , admittedAdmissionMode
  , admittedRemainingBudget
  , planGraphRewrite
  , planGraphRewriteNamespaced
  , validateAdmittedRewriteDelta
  )

-- A 2-node kernel template with raw (un-namespaced) local ids @k1 -> k2@.
kernelTemplate :: SubgraphSpec NodeId ()
kernelTemplate =
  SubgraphSpec
    { sgsTopology = toRelation (edge (NodeId "k1") (NodeId "k2") :: Graph NodeId)
    , sgsDefinitions = Map.fromList [(NodeId "k1", ()), (NodeId "k2", ())]
    , sgsEntryNodes = [NodeId "k1"]
    , sgsExitNodes = [NodeId "k2"]
    }

witnessA :: FrontierShapeWitness
witnessA = FrontierShapeWitness FrontierWitnessV1 "digest-a"

witnessB :: FrontierShapeWitness
witnessB = FrontierShapeWitness FrontierWitnessV1 "digest-b"

boundary :: FrontierShapeWitness -> KernelBoundary
boundary w =
  KernelBoundary
    { kbWitness = w
    , kbStateInRole = FrontierStateRole "state"
    , kbStateOutRole = FrontierStateRole "state"
    }

mkPolicy :: Natural -> KernelBoundary -> LoopPolicy
mkPolicy maxIters kb =
  LoopPolicy
    { lpMaxIterations = maxIters
    , lpExhaustion = IterationExhaustionFail
    , lpCheckpointCadence = 1
    , lpCancellationPoints = Set.empty
    , lpNamespaceRoot = NodeId "loop_root"
    , lpMaxSegmentLen = 64
    , lpMaxKernelNodes = 16
    , lpMaxKernelEdges = 32
    , lpMaxKernelDepth = 8
    , lpAggregation = AggregateAccumulate
    , lpMaxAggregatedItems = Nothing
    , lpRewriteInteraction = LoopKernelRewriteClosed
    , lpKernelBoundary = kb
    , lpKernelWitness = kernelWitnessForLocalSpec kernelTemplate
    , lpPolicyVersion = 1
    }

bigBudget :: RewriteBudget
bigBudget =
  RewriteBudget
    { rbAddedNodesMax = 100
    , rbAddedEdgesMax = 100
    , rbAddedDepthMax = 100
    , rbFrontierDeltaMax = 100
    , rbRewriteOpsMax = 100
    }

jint :: Int -> Aeson.Value
jint = Aeson.toJSON

spec :: Spec
spec = describe "runtime-bounded iteration pure core" $ do
  describe "admitRuntimeBound" $ do
    let policy = mkPolicy 10 (boundary witnessA)
    it "clamps a request above the cap to the cap" $
      admitRuntimeBound policy (RequestedBound 25) `shouldBe` Right (EffectiveBound 10)
    it "passes a request below the cap through unchanged" $
      admitRuntimeBound policy (RequestedBound 4) `shouldBe` Right (EffectiveBound 4)
    it "rejects a zero request" $
      admitRuntimeBound policy (RequestedBound 0) `shouldBe` Left BoundZeroNotAllowed
    it "rejects when the policy cap clamps to zero" $
      admitRuntimeBound (mkPolicy 0 (boundary witnessA)) (RequestedBound 5)
        `shouldBe` Left BoundZeroNotAllowed

  describe "checkSelfAppendStep (v1 frontier law)" $ do
    let kb = boundary witnessA
        anchor = NodeId "loop_root:iter_3:state_out"
    it "accepts a single designated loop-state exit equal to the anchor under an equal witness" $
      checkSelfAppendStep kb witnessA [anchor] anchor `shouldBe` Right ()
    it "rejects a multi-node loop-state continuation" $
      checkSelfAppendStep kb witnessA [anchor, NodeId "other"] anchor
        `shouldBe` Left (FrontierMultiNodeContinuation [anchor, NodeId "other"])
    it "rejects a witness mismatch (shape changed across the step)" $
      case checkSelfAppendStep kb witnessB [anchor] anchor of
        Left (FrontierWitnessMismatch _) -> pure ()
        other -> expectationFailure $ "expected FrontierWitnessMismatch, got " <> show other
    it "rejects an anchor that is not the designated loop-state output" $
      case checkSelfAppendStep kb witnessA [NodeId "elsewhere"] anchor of
        Left (FrontierAnchorMismatch _) -> pure ()
        other -> expectationFailure $ "expected FrontierAnchorMismatch, got " <> show other

  describe "planLoopStep" $ do
    let policy = mkPolicy 10 (boundary witnessA)
        anchor = NodeId "loop_root:iter_3:state_out"
    it "builds a flat-namespaced AppendAfter on the loop-state anchor" $
      case planLoopStep policy 3 5 anchor witnessA [anchor] kernelTemplate of
        Right (LoopContinue (AppendAfter gotAnchor spec') w) -> do
          gotAnchor `shouldBe` anchor
          -- namespaced under the FLAT seed loop_root:iter_4, not nested under the anchor
          sgsEntryNodes spec' `shouldBe` [NodeId "loop_root:iter_4:k1"]
          sgsExitNodes spec' `shouldBe` [NodeId "loop_root:iter_4:k2"]
          w `shouldBe` witnessA
        other -> expectationFailure $ "expected LoopContinue/AppendAfter, got " <> show other
    it "stops with a typed budget-exhausted reason when no iterations remain" $
      case planLoopStep policy 7 0 anchor witnessA [anchor] kernelTemplate of
        Right (LoopStop (StoppedBudgetExhausted n)) -> n `shouldBe` 7
        other -> expectationFailure $ "expected LoopStop, got " <> show other
    it "propagates the multi-node frontier rejection" $
      case planLoopStep policy 3 5 anchor witnessA [anchor, NodeId "x"] kernelTemplate of
        Left (FrontierMultiNodeContinuation _) -> pure ()
        other -> expectationFailure $ "expected Left FrontierMultiNodeContinuation, got " <> show other
    it "rejects a kernel template whose local id breaks the namespace segment discipline" $
      let badKernel =
            SubgraphSpec
              { sgsTopology = toRelation (edge (NodeId "bad:seg") (NodeId "k2") :: Graph NodeId)
              , sgsDefinitions = Map.fromList [(NodeId "bad:seg", ()), (NodeId "k2", ())]
              , sgsEntryNodes = [NodeId "bad:seg"]
              , sgsExitNodes = [NodeId "k2"]
              }
       in case planLoopStep policy 3 5 anchor witnessA [anchor] badKernel of
            Left (FrontierInvalidKernelLocalIds bad) -> bad `shouldContain` [NodeId "bad:seg"]
            other -> expectationFailure $ "expected FrontierInvalidKernelLocalIds, got " <> show other
    it "validateKernelLocalIds rejects a segment longer than the cap" $
      let longId = NodeId (T.replicate 65 "x")
          longKernel =
            SubgraphSpec
              { sgsTopology = toRelation (path [longId] :: Graph NodeId)
              , sgsDefinitions = Map.fromList [(longId, ())]
              , sgsEntryNodes = [longId]
              , sgsExitNodes = [longId]
              }
       in validateKernelLocalIds 64 longKernel `shouldBe` Left (FrontierInvalidKernelLocalIds [longId])

  describe "planLoopStep + planGraphRewriteNamespaced (loop step admission)" $ do
    let policy = mkPolicy 10 (boundary witnessA)
        anchor = NodeId "loop_root:iter_3:state_out"
        -- a topology whose only node is the prior iteration's loop-state anchor
        topo = toRelation (path [anchor] :: Graph NodeId)
        defs = Map.fromList [(anchor, ())]
    it "admits the flat-namespaced step without re-namespacing under the anchor" $
      case planLoopStep policy 3 5 anchor witnessA [anchor] kernelTemplate of
        Right (LoopContinue rewrite _) ->
          case planGraphRewriteNamespaced rewrite topo defs of
            Left errs -> expectationFailure $ "planGraphRewriteNamespaced failed: " <> show errs
            Right delta -> do
              -- ids stay flat under loop_root:iter_4, NOT nested under the anchor
              prdEntryNodes delta `shouldBe` [NodeId "loop_root:iter_4:k1"]
              prdExitNodes delta `shouldBe` [NodeId "loop_root:iter_4:k2"]
              prdCost delta `shouldSatisfy` \c -> rcAddedNodes c == 2
        other -> expectationFailure $ "expected LoopContinue, got " <> show other

  describe "initLoopControl / stepIterationBudget" $ do
    let policy = mkPolicy 10 (boundary witnessA)
        ctrl = initLoopControl policy (EffectiveBound 3)
    it "counts the seed iter_0 body against the admitted bound" $
      lcRemainingIterations ctrl `shouldBe` 2
    it "starts a one-body bound with no remaining self-appends" $
      lcRemainingIterations (initLoopControl policy (EffectiveBound 1)) `shouldBe` 0
    it "makes a one-body loop stop instead of planning iter_1 after the seed body" $
      case planLoopStep
        policy
        0
        (lcRemainingIterations (initLoopControl policy (EffectiveBound 1)))
        (NodeId "loop_root:iter_0:k")
        witnessA
        [NodeId "loop_root:iter_0:k"]
        kernelTemplate of
        Right (LoopStop (StoppedBudgetExhausted n)) -> n `shouldBe` 0
        other -> expectationFailure $ "expected LoopStop, got " <> show other
    it "decrements the remaining self-append budget" $
      lcRemainingIterations (stepIterationBudget ctrl) `shouldBe` 1
    it "saturates at zero (never underflows)" $
      lcRemainingIterations (stepIterationBudget (ctrl {lcRemainingIterations = 0})) `shouldBe` 0

  describe "aggregateEmitted" $ do
    let accumPolicy = mkPolicy 10 (boundary witnessA)
        emptyAgg = AggregationState {asItems = [], asCount = 0}
        fold p = foldl (\st v -> aggregateEmitted p st (Just v)) emptyAgg
    it "accumulates emitted values in order" $ do
      let st = fold accumPolicy [jint 0, jint 1, jint 2]
      asItems st `shouldBe` [jint 0, jint 1, jint 2]
      asCount st `shouldBe` 3
    it "is order-stable: re-folding the same prefix re-derives the same value" $
      fold accumPolicy [jint 0, jint 1, jint 2]
        `shouldBe` fold accumPolicy [jint 0, jint 1, jint 2]
    it "bounds accumulated payload at lpMaxAggregatedItems while still counting" $ do
      let st = fold (accumPolicy {lpMaxAggregatedItems = Just 2}) [jint 0, jint 1, jint 2]
      asItems st `shouldBe` [jint 0, jint 1]
      asCount st `shouldBe` 3
    it "ReduceLast keeps only the last emitted value" $ do
      let st = fold (accumPolicy {lpAggregation = AggregateReduceLast}) [jint 0, jint 1, jint 2]
      asItems st `shouldBe` [jint 2]
    it "Discard keeps nothing but counts" $ do
      let st = fold (accumPolicy {lpAggregation = AggregateDiscard}) [jint 0, jint 1]
      asItems st `shouldBe` []
      asCount st `shouldBe` 2

  describe "budgetExhaustionOutcome" $ do
    it "Fail policy yields a typed budget-exhausted outcome" $
      budgetExhaustionOutcome (mkPolicy 10 (boundary witnessA)) 8 (jint 9)
        `shouldBe` LoopBudgetExhausted 8
    it "Partial policy yields a partial result" $
      budgetExhaustionOutcome
        ((mkPolicy 10 (boundary witnessA)) {lpExhaustion = IterationExhaustionPartial})
        8
        (jint 9)
        `shouldBe` LoopPartial (jint 9) 8
    it "Fallback policy yields a fallback result" $
      budgetExhaustionOutcome
        ((mkPolicy 10 (boundary witnessA)) {lpExhaustion = IterationExhaustionFallback})
        8
        (jint 9)
        `shouldBe` LoopFallback (jint 9)

  describe "authorizeWitnessedStep (security gate)" $ do
    let single nid =
          SubgraphSpec
            { sgsTopology = toRelation (path [nid] :: Graph NodeId)
            , sgsDefinitions = Map.fromList [(nid, ())]
            , sgsEntryNodes = [nid]
            , sgsExitNodes = [nid]
            }
        policy =
          (mkPolicy 10 (boundary witnessA))
            { lpKernelWitness = kernelWitnessForLocalSpec (single (NodeId "k"))
            }
        -- lpNamespaceRoot = loop_root, maxIters = 10
        producer = NodeId "loop_root:iter_3:k"
        validSpec = single (NodeId "loop_root:iter_4:k")
        specFor n = single (NodeId ("loop_root:iter_" <> T.pack (show n) <> ":k"))
        validWitness = LoopStepWitness witnessA [producer]
        smallCost =
          RewriteCost
            { rcAddedNodes = 1
            , rcAddedEdges = 0
            , rcAddedDepth = 1
            , rcFrontierDelta = 0
            , rcRewriteOps = 1
            }
    it "accepts a bounded in-namespace self-append" $
      authorizeWitnessedStep policy producer validWitness (AppendAfter producer validSpec) smallCost
        `shouldBe` Right ()
    it "accepts and advances a control-authorized self-append" $ do
      let control =
            (initLoopControl policy (EffectiveBound 6))
              { lcRemainingIterations = 2
              }
          result =
            authorizeWitnessedStepWithControl
              policy
              control
              producer
              validWitness
              (Just (jint 42))
              (AppendAfter producer validSpec)
              smallCost
      fmap lcRemainingIterations result `shouldBe` Right 1
      fmap (asItems . lcAggregation) result `shouldBe` Right [jint 42]
    it "rejects a policy-valid append once the per-run effective bound is exhausted" $
      let producer2 = NodeId "loop_root:iter_2:k"
          exhaustedControl =
            (initLoopControl policy (EffectiveBound 3))
              { lcRemainingIterations = 0
              }
       in case authorizeWitnessedStepWithControl
            policy
            exhaustedControl
            producer2
            (LoopStepWitness witnessA [producer2])
            (Just (jint 99))
            (AppendAfter producer2 (specFor (3 :: Int)))
            smallCost of
            Left (StepIterationBudgetExhausted n) -> n `shouldBe` 3
            other -> expectationFailure $ "expected StepIterationBudgetExhausted, got " <> show other
    it "rejects a frontier witness mismatch before gas-neutral admission" $
      case authorizeWitnessedStep
        policy
        producer
        (LoopStepWitness witnessB [producer])
        (AppendAfter producer validSpec)
        smallCost of
        Left (StepFrontierViolation (FrontierWitnessMismatch _)) -> pure ()
        other ->
          expectationFailure $ "expected StepFrontierViolation/FrontierWitnessMismatch, got " <> show other
    it "rejects a multi-node loop-state continuation before gas-neutral admission" $
      case authorizeWitnessedStep
        policy
        producer
        (LoopStepWitness witnessA [producer, NodeId "loop_root:iter_3:other"])
        (AppendAfter producer validSpec)
        smallCost of
        Left (StepFrontierViolation (FrontierMultiNodeContinuation _)) -> pure ()
        other ->
          expectationFailure $
            "expected StepFrontierViolation/FrontierMultiNodeContinuation, got " <> show other
    it "rejects a canonical next spec that is not the policy-certified kernel" $
      case authorizeWitnessedStep
        policy
        producer
        validWitness
        (AppendAfter producer (single (NodeId "loop_root:iter_4:other")))
        smallCost of
        Left (StepKernelWitnessMismatch _) -> pure ()
        other -> expectationFailure $ "expected StepKernelWitnessMismatch, got " <> show other
    it "rejects a non-AppendAfter (ExpandNode) so it cannot bypass gas" $
      authorizeWitnessedStep
        policy
        producer
        validWitness
        (ExpandNode producer ExpandReplaceNode validSpec)
        smallCost
        `shouldBe` Left StepNotAppendAfter
    it "rejects a non-self-append (anchor /= producer)" $
      case authorizeWitnessedStep
        policy
        (NodeId "loop_root:iter_3:k")
        validWitness
        (AppendAfter (NodeId "elsewhere") validSpec)
        smallCost of
        Left (StepAnchorMismatch _) -> pure ()
        other -> expectationFailure $ "expected StepAnchorMismatch, got " <> show other
    it "rejects an oversized kernel (per-append fan-out bound)" $
      case authorizeWitnessedStep
        policy
        producer
        validWitness
        (AppendAfter producer validSpec)
        (smallCost {rcAddedNodes = 999}) of
        Left (StepKernelTooLarge _) -> pure ()
        other -> expectationFailure $ "expected StepKernelTooLarge, got " <> show other
    it "rejects an inserted id beyond the iteration cap" $
      case authorizeWitnessedStep
        policy
        producer
        validWitness
        (AppendAfter producer (single (NodeId "loop_root:iter_999:k")))
        smallCost of
        Left (StepNamespaceViolation _) -> pure ()
        other -> expectationFailure $ "expected StepNamespaceViolation, got " <> show other
    it "rejects an inserted id outside the namespace root" $
      case authorizeWitnessedStep
        policy
        producer
        validWitness
        (AppendAfter producer (single (NodeId "evil:node")))
        smallCost of
        Left (StepNamespaceViolation _) -> pure ()
        other -> expectationFailure $ "expected StepNamespaceViolation, got " <> show other
    it "rejects a skipped (non-canonical-next) iteration index" $
      -- producer iter_3 may only append iter_4, not iter_5
      case authorizeWitnessedStep
        policy
        producer
        validWitness
        (AppendAfter producer (single (NodeId "loop_root:iter_5:k")))
        smallCost of
        Left (StepNamespaceViolation _) -> pure ()
        other -> expectationFailure $ "expected StepNamespaceViolation, got " <> show other
    it "rejects a leading-zero aliased next index (iter_04 is not iter_4)" $
      case authorizeWitnessedStep
        policy
        producer
        validWitness
        (AppendAfter producer (single (NodeId "loop_root:iter_04:k")))
        smallCost of
        Left (StepNamespaceViolation _) -> pure ()
        other -> expectationFailure $ "expected StepNamespaceViolation, got " <> show other
    it "rejects when the producer's next iteration reaches the cap" $
      -- iter_0 is the first body execution, so producer iter_9 may not append
      -- iter_10 when lpMaxIterations = 10.
      case authorizeWitnessedStep
        policy
        (NodeId "loop_root:iter_9:k")
        (LoopStepWitness witnessA [NodeId "loop_root:iter_9:k"])
        (AppendAfter (NodeId "loop_root:iter_9:k") (single (NodeId "loop_root:iter_10:k")))
        smallCost of
        Left (StepIterationCapExceeded n) -> n `shouldBe` 10
        other -> expectationFailure $ "expected StepIterationCapExceeded, got " <> show other
    it "rejects appending iter_1 under a one-body cap because iter_0 is the seed body" $
      case authorizeWitnessedStep
        ((mkPolicy 1 (boundary witnessA)) {lpKernelWitness = kernelWitnessForLocalSpec (single (NodeId "k"))})
        (NodeId "loop_root:iter_0:k")
        (LoopStepWitness witnessA [NodeId "loop_root:iter_0:k"])
        (AppendAfter (NodeId "loop_root:iter_0:k") (single (NodeId "loop_root:iter_1:k")))
        smallCost of
        Left (StepIterationCapExceeded n) -> n `shouldBe` 1
        other -> expectationFailure $ "expected StepIterationCapExceeded, got " <> show other
    it "rejects a producer that is not a loop-namespace node" $
      case authorizeWitnessedStep
        policy
        (NodeId "random")
        (LoopStepWitness witnessA [NodeId "random"])
        (AppendAfter (NodeId "random") validSpec)
        smallCost of
        Left (StepProducerNotInNamespace _) -> pure ()
        other -> expectationFailure $ "expected StepProducerNotInNamespace, got " <> show other
    it "rejects a producer with no local segment after the iteration index" $
      case authorizeWitnessedStep
        policy
        (NodeId "loop_root:iter_3")
        (LoopStepWitness witnessA [NodeId "loop_root:iter_3"])
        (AppendAfter (NodeId "loop_root:iter_3") validSpec)
        smallCost of
        Left (StepProducerNotInNamespace _) -> pure ()
        other -> expectationFailure $ "expected StepProducerNotInNamespace, got " <> show other
    it "rejects a producer with a nested local segment" $
      case authorizeWitnessedStep
        policy
        (NodeId "loop_root:iter_3:a:b")
        (LoopStepWitness witnessA [NodeId "loop_root:iter_3:a:b"])
        (AppendAfter (NodeId "loop_root:iter_3:a:b") validSpec)
        smallCost of
        Left (StepProducerNotInNamespace _) -> pure ()
        other -> expectationFailure $ "expected StepProducerNotInNamespace, got " <> show other

  describe "witnessed admission is gas-neutral (ADR 0056)" $ do
    -- a -> b, append a 2-node fragment after b
    let topo = toRelation (edge (NodeId "a") (NodeId "b") :: Graph NodeId)
        defs = Map.fromList [(NodeId "a", ()), (NodeId "b", ())]
        sub =
          SubgraphSpec
            (toRelation (edge (NodeId "s1") (NodeId "s2") :: Graph NodeId))
            (Map.fromList [(NodeId "s1", ()), (NodeId "s2", ())])
            [NodeId "s1"]
            [NodeId "s2"]
        rewrite = AppendAfter (NodeId "b") sub
    it "leaves the rewrite budget unchanged while a gassed admission debits it" $
      case planGraphRewrite rewrite topo defs of
        Left errs -> expectationFailure $ "planGraphRewrite failed: " <> show errs
        Right delta -> do
          let wit = admitWitnessedDelta bigBudget delta
          admittedRemainingBudget wit `shouldBe` bigBudget
          admittedAdmissionMode wit `shouldBe` AdmissionWitnessed
          case admitRewriteDelta bigBudget delta of
            Left err -> expectationFailure $ "gassed admission rejected: " <> show err
            Right gas -> do
              admittedAdmissionMode gas `shouldBe` AdmissionGassed
              (admittedRemainingBudget gas == bigBudget) `shouldBe` False
    it "validateAdmittedRewriteDelta accepts both the witnessed (gas-neutral) and gassed deltas" $
      case planGraphRewrite rewrite topo defs of
        Left errs -> expectationFailure $ "planGraphRewrite failed: " <> show errs
        Right delta -> do
          let wit = admitWitnessedDelta bigBudget delta
          case validateAdmittedRewriteDelta bigBudget delta wit of
            Right () -> pure ()
            Left errs -> expectationFailure $ "witnessed validation failed: " <> show errs
          case admitRewriteDelta bigBudget delta of
            Left err -> expectationFailure $ "gassed admission rejected: " <> show err
            Right gas ->
              case validateAdmittedRewriteDelta bigBudget delta gas of
                Right () -> pure ()
                Left errs -> expectationFailure $ "gassed validation failed: " <> show errs
