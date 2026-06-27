{- |
Module      : Cortex.Wire.Circuit.CompilerSpec
Description : Tests for Cortex.Wire.Circuit.Compiler.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.Circuit.CompilerSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Test.HUnit.Lang (assertFailure)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Relation (..)
  , ValidationError (..)
  , edge
  , relVertices
  , successors
  , toRelation
  )
import Cortex.Pulse.Hydrate (planRewriteDelta)
import Cortex.Pulse.Memory (defaultMemoryStrategy, discardMemoryHandle)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( ReplayPolicy (..)
  , RewriteExhaustionPolicy (..)
  , SomeStagePlan (..)
  , StageActionId (..)
  , StageContext (..)
  , StageDefinition (..)
  , StageLatentBranch (..)
  , StageLatentCondition (..)
  , StageLatentDeltaSignature (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , StageResult (..)
  , StageTemplateId (..)
  , liftChainAction
  , stageActionId
  , stageTemplateId
  )
import Cortex.Pulse.Rewrite
  ( AnchorBoundaryUse (..)
  , BoundaryLaw (..)
  , BoundaryResourceUse (..)
  , BudgetContext (..)
  , BudgetedBoundaryResourceUse (..)
  , GraphRewrite (..)
  , PlannedRewriteDelta (..)
  , RewriteCost (..)
  , SubgraphSpec (..)
  , admittedBoundaryResourceUse
  , planGraphRewriteWithAdmissionWitness
  , plannedGraphRewriteDelta
  )
import Cortex.Pulse.Types (defaultRewriteBudget)
import Cortex.Wire (WirePayloadKind (..), WireValue (..), mkWireValue)
import Cortex.Wire.Circuit
  ( CircuitArtifactBoundary (..)
  , CircuitCompatibilityWitness (..)
  , CircuitCompileError (..)
  , CircuitCondition (..)
  , CircuitConditionBinding (..)
  , CircuitConditionBranch (..)
  , CircuitConditionNode (..)
  , CircuitConditionSelection (..)
  , CircuitExpr (..)
  , CircuitIR (..)
  , CircuitLoweringError (..)
  , CircuitNodeRef (..)
  , CircuitPulseBinder (..)
  , CircuitPulseConfig (..)
  , CircuitRewriteBoundary (..)
  , CircuitSignalBoundary (..)
  , CircuitTaskNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitFragment (..)
  , CompiledCircuitNode (..)
  , committedVariantSelectKeys
  , committedVariantSelection
  , compileCircuitIR
  , lowerCompiledCircuitToSomeStagePlan
  , lowerCompiledCircuitToStagePlan
  )

spec :: Spec
spec = do
  describe "ADR 0062 committed-variant select" $ do
    it "routes a committed then-key label to the then branch" $ do
      let selection = committedVariantSelection ["ok"] ["err"] (committedVariantInput "producer" "ok")
      selection.circuitConditionSelectionBranch `shouldBe` CircuitConditionThen

    it "routes a committed else-key label to the else branch" $ do
      let selection = committedVariantSelection ["ok"] ["err"] (committedVariantInput "producer" "err")
      selection.circuitConditionSelectionBranch `shouldBe` CircuitConditionElse

    it "dispatches N-way: an else-set label among several routes to else" $ do
      let selection =
            committedVariantSelection ["ok"] ["err", "stop"] (committedVariantInput "producer" "stop")
      selection.circuitConditionSelectionBranch `shouldBe` CircuitConditionElse

    it "is deterministic for the same committed inputs (resume-safe, no effect)" $ do
      let inputs = committedVariantInput "producer" "ok"
      committedVariantSelection ["ok"] ["err"] inputs
        `shouldBe` committedVariantSelection ["ok"] ["err"] inputs

    it "passes the committed variant payload through as the condition output" $ do
      let selection = committedVariantSelection ["ok"] ["err"] (committedVariantInput "producer" "ok")
      selection.circuitConditionSelectionOutput
        `shouldBe` Aeson.toJSON
          ((mkWireValue "VariantContract" WirePayloadJson Nothing (Aeson.Number 1)) {wireValuePort = Just "ok"})

    it "defaults to else with a null output when no committed select label is present" $ do
      let selection =
            committedVariantSelection ["ok"] ["err"] (committedVariantInput "producer" "unrelated")
      selection `shouldBe` CircuitConditionSelection Aeson.Null CircuitConditionElse

    it "parses thenKeys/elseKeys from condition metadata" $
      committedVariantSelectKeys
        (Aeson.object ["thenKeys" Aeson..= (["ok"] :: [T.Text]), "elseKeys" Aeson..= (["err"] :: [T.Text])])
        `shouldBe` Right (["ok"], ["err"])

    it "rejects malformed condition metadata" $
      case committedVariantSelectKeys (Aeson.object ["thenKeys" Aeson..= (["ok"] :: [T.Text])]) of
        Left (CircuitConditionMetadataInvalid _) -> pure ()
        other -> expectationFailure ("expected CircuitConditionMetadataInvalid, got " <> show other)

  describe "compileCircuitIR" $ do
    it "compiles a circuit into a deterministic graph artifact with latent conditional branches" $ do
      compiled <- requireCompiled sampleCircuitIR
      compiledAgain <- requireCompiled sampleCircuitIR
      compiledAgain `shouldBe` compiled
      compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "planner"]
      compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "reviewer"]
      Map.keys compiled.compiledCircuitNodes
        `shouldSatisfy` all
          ( `elem`
              [ CircuitNodeRef "__cortex_workflow__/condition/1"
              , CircuitNodeRef "planner"
              , CircuitNodeRef "reviewer"
              , CircuitNodeRef "risks"
              , CircuitNodeRef "summary"
              ]
          )
      Map.keys compiled.compiledCircuitNodes
        `shouldSatisfy` any isSyntheticConditionRef
      case Map.lookup (CircuitNodeRef "__cortex_workflow__/condition/1") compiled.compiledCircuitNodes of
        Just (CompiledCircuitCondition conditionNode) -> do
          Map.keys conditionNode.circuitConditionNodeThenFragment.compiledCircuitFragmentNodes
            `shouldBe` [CircuitNodeRef "analyst"]
          conditionNode.circuitConditionNodeElseFragment `shouldBe` Nothing
        other ->
          expectationFailure ("Expected latent condition node, got: " <> show other)

    it "changes the compatibility witness when circuit semantics change" $ do
      compiled <- requireCompiled sampleCircuitIR
      changed <- requireCompiled changedSampleCircuitIR
      compiled.compiledCircuitCompatibility
        `shouldNotBe` changed.compiledCircuitCompatibility

    it "keeps conditional branches latent and fans out only the post-conditional topology" $ do
      compiled <- requireCompiled sampleCircuitIR
      successors compiled.compiledCircuitTopology (CircuitNodeRef "__cortex_workflow__/condition/1")
        `shouldBe` Set.fromList [CircuitNodeRef "summary", CircuitNodeRef "risks"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "summary")
        `shouldBe` Set.singleton (CircuitNodeRef "reviewer")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "risks")
        `shouldBe` Set.singleton (CircuitNodeRef "reviewer")

    it "compiles nested conditional branches recursively as latent fragments" $ do
      compiled <- requireCompiled nestedConditionalCircuitIR
      case Map.lookup (CircuitNodeRef "__cortex_workflow__/condition/1") compiled.compiledCircuitNodes of
        Just (CompiledCircuitCondition outerCondition) ->
          case Map.lookup
            (CircuitNodeRef "__cortex_workflow__/condition/1/0")
            outerCondition.circuitConditionNodeThenFragment.compiledCircuitFragmentNodes of
            Just (CompiledCircuitCondition nestedCondition) ->
              Map.keys nestedCondition.circuitConditionNodeThenFragment.compiledCircuitFragmentNodes
                `shouldBe` [CircuitNodeRef "nested_then"]
            other ->
              expectationFailure ("Expected nested latent condition node, got: " <> show other)
        other ->
          expectationFailure ("Expected outer latent condition node, got: " <> show other)

    it "captures fan-out join fan-out circuits with stable entry and exit nodes" $ do
      compiled <- requireCompiled quarterlyRebalanceCircuitIR
      compiled.compiledCircuitEntryNodes
        `shouldBe` [ CircuitNodeRef "fetch_positions"
                   , CircuitNodeRef "fetch_market_data"
                   , CircuitNodeRef "fetch_risk_limits"
                   ]
      compiled.compiledCircuitExitNodes
        `shouldBe` [CircuitNodeRef "report_artifact"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "fetch_positions")
        `shouldBe` Set.singleton (CircuitNodeRef "compute_target_allocations")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "fetch_market_data")
        `shouldBe` Set.singleton (CircuitNodeRef "compute_target_allocations")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "fetch_risk_limits")
        `shouldBe` Set.singleton (CircuitNodeRef "compute_target_allocations")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "compute_target_allocations")
        `shouldBe` Set.fromList
          [ CircuitNodeRef "propose_equity_trades"
          , CircuitNodeRef "propose_fixed_income_trades"
          , CircuitNodeRef "propose_derivatives_overlay"
          ]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "signoff_equities")
        `shouldBe` Set.singleton (CircuitNodeRef "aggregate_execution_plan")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "signoff_fixed_income")
        `shouldBe` Set.singleton (CircuitNodeRef "aggregate_execution_plan")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "signoff_derivatives")
        `shouldBe` Set.singleton (CircuitNodeRef "aggregate_execution_plan")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "risk_desk_approval")
        `shouldBe` Set.singleton (CircuitNodeRef "signoff_derivatives")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "aggregate_execution_plan")
        `shouldBe` Set.singleton (CircuitNodeRef "report_artifact")

    it "rejects duplicate node refs" $ do
      compileCircuitIR duplicateNodeRefCircuitIR
        `shouldBe` Left (CircuitDuplicateNodeRef (CircuitNodeRef "shared"))

    it "CompiledCircuit JSON roundtrip" $ do
      compiled <- requireCompiled quarterlyRebalanceCircuitIR
      let encoded = Aeson.encode compiled
          decoded = Aeson.eitherDecode encoded :: Either String CompiledCircuit
      decoded `shouldBe` Right compiled

  describe "lowerCompiledCircuitToStagePlan" $ do
    it "lowers a compiled circuit through an explicit Pulse binder" $ do
      compiled <- requireCompiled simpleLinearCircuitIR
      stagePlan <- requireLoweredStagePlan defaultBinder compiled

      Map.keys stagePlan.spDefinitions
        `shouldBe` [ NodeId "planner"
                   , NodeId "reviewer"
                   ]

    it "lowers fan-out join fan-out circuits without collapsing the frontier structure" $ do
      compiled <- requireCompiled quarterlyRebalanceCircuitIR
      stagePlan <- requireLoweredStagePlan defaultBinder compiled
      successors stagePlan.spTopology (NodeId "compute_target_allocations")
        `shouldBe` Set.fromList
          [ NodeId "propose_equity_trades"
          , NodeId "propose_fixed_income_trades"
          , NodeId "propose_derivatives_overlay"
          ]
      successors stagePlan.spTopology (NodeId "aggregate_execution_plan")
        `shouldBe` Set.singleton (NodeId "report_artifact")

    let nilStageCtx =
          let b = defaultRewriteBudget
           in StageContext
                { scRunId = UUID.nil
                , scNodeId = NodeId "__test__"
                , scInputs = Map.empty
                , scAttempt = 1
                , scBudgetContext = BudgetContext {bcInitialBudget = b, bcRemainingBudget = b}
                , scRewriteRejection = Nothing
                , scRetryFailure = Nothing
                , scMemoryStrategy = defaultMemoryStrategy
                , scMemory = discardMemoryHandle
                }

    it "lowers a conditional stage that appends the selected branch as a rewrite" $ do
      compiled <- requireCompiled sampleCircuitIR
      stagePlan <- requireLoweredStagePlan thenBranchBinder compiled
      let conditionNodeId = NodeId "__cortex_workflow__/condition/1"
      conditionStage <-
        requireLookup "Expected lowered condition stage" conditionNodeId stagePlan.spDefinitions
      stageResult <- conditionStage.sdAction nilStageCtx
      case stageResult of
        StageRewrite (Aeson.Bool True) rewrite ->
          case planRewriteDelta rewrite stagePlan of
            Left errs ->
              expectationFailure ("Expected planned conditional rewrite, got errors: " <> show errs)
            Right delta -> do
              successors delta.prdTopology conditionNodeId
                `shouldBe` Set.singleton (NodeId "__cortex_workflow__/condition/1:analyst")
              successors delta.prdTopology (NodeId "__cortex_workflow__/condition/1:analyst")
                `shouldBe` Set.fromList [NodeId "summary", NodeId "risks"]
        _ ->
          expectationFailure "Expected StageRewrite for selected then branch."

    it "admits only the selected latent branch through the rewrite witness surface" $ do
      compiled <- requireCompiled binaryConditionalCircuitIR
      stagePlan <- requireLoweredStagePlan thenBranchBinder compiled
      let conditionNodeId = NodeId "__cortex_workflow__/condition/1"
          selectedNodeId = NodeId "then_work"
          unselectedNodeId = NodeId "else_work"
          selectedRuntimeNodeId = NodeId "__cortex_workflow__/condition/1:then_work"
          unselectedRuntimeNodeId = NodeId "__cortex_workflow__/condition/1:else_work"
      conditionStage <-
        requireLookup "Expected lowered condition stage" conditionNodeId stagePlan.spDefinitions
      stageResult <- conditionStage.sdAction nilStageCtx
      case stageResult of
        StageRewrite (Aeson.Bool True) rewrite@(AppendAfter anchor selectedSpec) -> do
          anchor `shouldBe` conditionNodeId
          Set.member selectedNodeId (relVertices selectedSpec.sgsTopology) `shouldBe` True
          Set.member unselectedNodeId (relVertices selectedSpec.sgsTopology) `shouldBe` False
          witness <-
            requireRight
              "Expected selected branch rewrite admission witness"
              ( planGraphRewriteWithAdmissionWitness
                  defaultRewriteBudget
                  rewrite
                  stagePlan.spTopology
                  stagePlan.spDefinitions
              )
          let delta = plannedGraphRewriteDelta witness
          delta.prdNewNodes `shouldBe` Set.singleton selectedRuntimeNodeId
          Set.member unselectedRuntimeNodeId delta.prdNewNodes `shouldBe` False
          delta.prdAddedEdges
            `shouldBe` Set.fromList
              [ (conditionNodeId, selectedRuntimeNodeId)
              , (selectedRuntimeNodeId, NodeId "done")
              ]
          delta.prdCost
            `shouldBe` RewriteCost
              { rcAddedNodes = 1
              , rcAddedEdges = 2
              , rcAddedDepth = 1
              , rcFrontierDelta = 0
              , rcRewriteOps = 1
              }
          admittedBoundaryResourceUse witness
            `shouldBe` BudgetedBoundaryResourceUse
              { bbruUse =
                  BoundaryResourceUse
                    { bruLaw = AppendContinuation
                    , bruSlotAnchor = conditionNodeId
                    , bruAnchorBoundaryUse = AnchorBoundaryRetained
                    }
              , bbruCost = delta.prdCost
              }
        StageRewrite {} ->
          expectationFailure "Expected selected branch append rewrite."
        StageComplete {} ->
          expectationFailure "Expected selected branch StageRewrite, got completion."
        StageSuspend {} ->
          expectationFailure "Expected selected branch StageRewrite, got suspension."
        StageRejectRewrite {} ->
          expectationFailure "Expected selected branch StageRewrite, got rewrite rejection."
        StageLoopStep {} ->
          expectationFailure "Expected selected branch StageRewrite, got loop step."
        StageFail {} ->
          expectationFailure "Expected selected branch StageRewrite, got typed failure."

    it "completes without a rewrite when the implicit else branch is selected" $ do
      compiled <- requireCompiled sampleCircuitIR
      stagePlan <- requireLoweredStagePlan elseBranchBinder compiled
      let conditionNodeId = NodeId "__cortex_workflow__/condition/1"
      conditionStage <-
        requireLookup "Expected lowered condition stage" conditionNodeId stagePlan.spDefinitions
      stageResult <- conditionStage.sdAction nilStageCtx
      case stageResult of
        StageComplete (Aeson.Bool False) -> pure ()
        _ -> expectationFailure "Expected StageComplete for the implicit else branch."

    it "preserves condition-stage template and action identifiers from the binder" $ do
      compiled <- requireCompiled sampleCircuitIR
      let idBoundBinder =
            defaultBinder
              { bindCircuitConditionNode =
                  const . Right $
                    (conditionBinding CircuitConditionThen (Aeson.Bool True))
                      { circuitConditionTemplateId = Just (StageTemplateId "condition/template")
                      , circuitConditionActionId = Just (StageActionId "condition/action")
                      }
              }
      stagePlan <- requireLoweredStagePlan idBoundBinder compiled
      let conditionNodeId = NodeId "__cortex_workflow__/condition/1"
      conditionStage <-
        requireLookup "Expected lowered condition stage" conditionNodeId stagePlan.spDefinitions
      conditionStage.sdTemplateId `shouldBe` StageTemplateId "condition/template"
      conditionStage.sdActionId `shouldBe` StageActionId "condition/action"

    it "carries recursive latent condition metadata alongside the lowered stage plan" $ do
      compiled <- requireCompiled nestedConditionalCircuitIR
      SomeStagePlan _ latentConditions <-
        requireRight
          "Expected successful lowering with latent metadata"
          (lowerCompiledCircuitToSomeStagePlan pulseConfig thenBranchBinder compiled)
      case latentConditions of
        [outerCondition] -> do
          outerCondition.slcAnchorNodeId `shouldBe` NodeId "__cortex_workflow__/condition/1"
          fmap (.slbBranchId) outerCondition.slcBranches `shouldBe` ["then"]
          case outerCondition.slcBranches of
            [outerBranch] -> do
              outerBranch.slbDeltaSignature.sldsBoundaryResourceUse
                `shouldBe` BoundaryResourceUse
                  { bruLaw = AppendContinuation
                  , bruSlotAnchor = NodeId "__cortex_workflow__/condition/1"
                  , bruAnchorBoundaryUse = AnchorBoundaryRetained
                  }
              fmap (.slcAnchorNodeId) outerBranch.slbNestedConditions
                `shouldBe` [NodeId "__cortex_workflow__/condition/1:__cortex_workflow__/condition/1/0"]
            _ ->
              expectationFailure "Expected exactly one outer latent branch"
        other ->
          expectationFailure ("Expected one top-level latent condition, got: " <> show other)

    it "rejects binders that return a mismatched stage id" $ do
      compiled <- requireCompiled simpleLinearCircuitIR
      case lowerCompiledCircuitToStagePlan pulseConfig mismatchedBinder compiled of
        Left (CircuitStageRefMismatch (CircuitNodeRef "planner") (NodeId "planner:mismatch")) ->
          pure ()
        other ->
          expectationFailure ("Expected CircuitStageRefMismatch, got: " <> show (fmap (.spTopology) other))

    it "rejects compiled circuits whose lowered topology is cyclic" $ do
      compatibility <- requireCompatibilityWitness simpleLinearCircuitIR
      let cyclicCompiled =
            CompiledCircuit
              { compiledCircuitId = "cyclic"
              , compiledCircuitLabel = "Cyclic circuit"
              , compiledCircuitCompatibility = compatibility
              , compiledCircuitEntryNodes = [CircuitNodeRef "a"]
              , compiledCircuitExitNodes = [CircuitNodeRef "b"]
              , compiledCircuitTopology =
                  toRelation
                    ( edge (CircuitNodeRef "a") (CircuitNodeRef "b")
                        <> edge (CircuitNodeRef "b") (CircuitNodeRef "a")
                    )
              , compiledCircuitNodes =
                  Map.fromList
                    [ (CircuitNodeRef "a", CompiledCircuitTask (taskNode "a" "A"))
                    , (CircuitNodeRef "b", CompiledCircuitTask (taskNode "b" "B"))
                    ]
              , compiledCircuitMetadata = Aeson.object []
              }
      case lowerCompiledCircuitToStagePlan pulseConfig defaultBinder cyclicCompiled of
        Left (CircuitLoweredGraphInvalid (GraphHasCycle cycleNodes)) ->
          Set.fromList cycleNodes `shouldBe` Set.fromList [NodeId "a", NodeId "b"]
        other ->
          expectationFailure
            ("Expected CircuitLoweredGraphInvalid with cycle details, got: " <> show (fmap (.spTopology) other))

{- | A select-boundary producer's committed variant output: one WireValue whose
port is the chosen variant label (ADR 0062).
-}
committedVariantInput :: T.Text -> T.Text -> Map.Map NodeId Aeson.Value
committedVariantInput producer label =
  Map.singleton
    (NodeId producer)
    ( Aeson.toJSON
        ( (mkWireValue "VariantContract" WirePayloadJson Nothing (Aeson.Number 1))
            { wireValuePort = Just label
            }
        )
    )

requireCompiled :: CircuitIR -> IO CompiledCircuit
requireCompiled circuitIr =
  requireRight "Expected successful circuit compilation" (compileCircuitIR circuitIr)

requireCompatibilityWitness :: CircuitIR -> IO CircuitCompatibilityWitness
requireCompatibilityWitness circuitIr =
  compiledCircuitCompatibility <$> requireCompiled circuitIr

requireLoweredStagePlan :: CircuitPulseBinder -> CompiledCircuit -> IO (StagePlan NodeId)
requireLoweredStagePlan binder compiled =
  requireRight
    "Expected successful lowering"
    (lowerCompiledCircuitToStagePlan pulseConfig binder compiled)

requireLookup :: Ord k => String -> k -> Map.Map k v -> IO v
requireLookup message key values =
  maybe (assertFailure message) pure (Map.lookup key values)

requireRight :: Show err => String -> Either err value -> IO value
requireRight message =
  either (assertFailure . ((message <> ", got: ") <>) . show) pure

isSyntheticConditionRef :: CircuitNodeRef -> Bool
isSyntheticConditionRef (CircuitNodeRef refText) =
  "__cortex_workflow__/condition/" `T.isPrefixOf` refText

sampleCircuitIR :: CircuitIR
sampleCircuitIR =
  CircuitIR
    { circuitIrId = "sample"
    , circuitIrLabel = "Sample circuit"
    , circuitIrRoot =
        CircuitSequence
          ( CircuitTask (taskNode "planner" "Planner")
              :| [ CircuitConditional
                     (CircuitConditionRef "needs_analysis")
                     (CircuitTask (taskNode "analyst" "Analyst"))
                     Nothing
                 , CircuitParallel
                     ( CircuitTask (taskNode "summary" "Summary")
                         :| [CircuitTask (taskNode "risks" "Risks")]
                     )
                 , CircuitTask (taskNode "reviewer" "Reviewer")
                 ]
          )
    , circuitIrMetadata = Aeson.object []
    }

changedSampleCircuitIR :: CircuitIR
changedSampleCircuitIR =
  sampleCircuitIR
    { circuitIrRoot =
        CircuitSequence
          ( CircuitTask (taskNode "planner" "Planner")
              :| [ CircuitConditional
                     (CircuitConditionRef "needs_analysis")
                     (CircuitTask (taskNode "analyst" "Analyst"))
                     Nothing
                 , CircuitParallel
                     ( CircuitTask (taskNode "summary" "Summary")
                         :| [ CircuitTask (taskNode "risks" "Risks")
                            , CircuitTask (taskNode "open_gaps" "Open gaps")
                            ]
                     )
                 , CircuitTask (taskNode "reviewer" "Reviewer")
                 ]
          )
    }

quarterlyRebalanceCircuitIR :: CircuitIR
quarterlyRebalanceCircuitIR =
  CircuitIR
    { circuitIrId = "quarterly-rebalance"
    , circuitIrLabel = "Quarterly Portfolio Rebalance"
    , circuitIrRoot =
        CircuitSequence
          ( CircuitParallel
              ( CircuitTask (taskNode "fetch_positions" "Fetch Positions")
                  :| [ CircuitTask (taskNode "fetch_market_data" "Fetch Market Data")
                     , CircuitTask (taskNode "fetch_risk_limits" "Fetch Risk Limits")
                     ]
              )
              :| [ CircuitTask (taskNode "compute_target_allocations" "Compute Target Allocations")
                 , CircuitParallel
                     ( CircuitSequence
                         ( CircuitTask (taskNode "propose_equity_trades" "Propose Equity Trades")
                             :| [CircuitTask (taskNode "signoff_equities" "Sign Off Equities")]
                         )
                         :| [ CircuitSequence
                                ( CircuitTask (taskNode "propose_fixed_income_trades" "Propose Fixed Income Trades")
                                    :| [CircuitTask (taskNode "signoff_fixed_income" "Sign Off Fixed Income")]
                                )
                            , CircuitSequence
                                ( CircuitTask (taskNode "propose_derivatives_overlay" "Propose Derivatives Overlay")
                                    :| [ CircuitAwaitSignal
                                           CircuitSignalBoundary
                                             { circuitSignalBoundaryRef = CircuitNodeRef "risk_desk_approval"
                                             , circuitSignalName = "risk_desk_approval"
                                             , circuitSignalDescription = Just "Wait for risk desk approval"
                                             , circuitSignalMetadata = Aeson.object []
                                             }
                                       , CircuitTask (taskNode "signoff_derivatives" "Sign Off Derivatives")
                                       ]
                                )
                            ]
                     )
                 , CircuitTask (taskNode "aggregate_execution_plan" "Aggregate Execution Plan")
                 , CircuitArtifact
                     CircuitArtifactBoundary
                       { circuitArtifactBoundaryRef = CircuitNodeRef "report_artifact"
                       , circuitArtifactKind = "report"
                       , circuitArtifactLabel = "Rebalance Report"
                       , circuitArtifactMetadata = Aeson.object []
                       }
                 ]
          )
    , circuitIrMetadata = Aeson.object []
    }

simpleLinearCircuitIR :: CircuitIR
simpleLinearCircuitIR =
  CircuitIR
    { circuitIrId = "simple"
    , circuitIrLabel = "Simple circuit"
    , circuitIrRoot =
        CircuitSequence
          ( CircuitTask (taskNode "planner" "Planner")
              :| [CircuitTask (taskNode "reviewer" "Reviewer")]
          )
    , circuitIrMetadata = Aeson.object []
    }

binaryConditionalCircuitIR :: CircuitIR
binaryConditionalCircuitIR =
  CircuitIR
    { circuitIrId = "binary-conditional"
    , circuitIrLabel = "Binary conditional circuit"
    , circuitIrRoot =
        CircuitSequence
          ( CircuitTask (taskNode "planner" "Planner")
              :| [ CircuitConditional
                     (CircuitConditionRef "needs_branch")
                     (CircuitTask (taskNode "then_work" "Then Work"))
                     (Just (CircuitTask (taskNode "else_work" "Else Work")))
                 , CircuitTask (taskNode "done" "Done")
                 ]
          )
    , circuitIrMetadata = Aeson.object []
    }

duplicateNodeRefCircuitIR :: CircuitIR
duplicateNodeRefCircuitIR =
  CircuitIR
    { circuitIrId = "duplicate-node-ref"
    , circuitIrLabel = "Duplicate node ref"
    , circuitIrRoot =
        CircuitSequence
          ( CircuitTask (taskNode "shared" "Shared")
              :| [CircuitTask (taskNode "shared" "Shared again")]
          )
    , circuitIrMetadata = Aeson.object []
    }

nestedConditionalCircuitIR :: CircuitIR
nestedConditionalCircuitIR =
  CircuitIR
    { circuitIrId = "nested-conditional"
    , circuitIrLabel = "Nested conditional"
    , circuitIrRoot =
        CircuitSequence
          ( CircuitTask (taskNode "planner" "Planner")
              :| [ CircuitConditional
                     (CircuitConditionRef "outer")
                     ( CircuitConditional
                         (CircuitConditionRef "inner")
                         (CircuitTask (taskNode "nested_then" "Nested Then"))
                         (Just (CircuitTask (taskNode "nested_else" "Nested Else")))
                     )
                     Nothing
                 , CircuitTask (taskNode "reviewer" "Reviewer")
                 ]
          )
    , circuitIrMetadata = Aeson.object []
    }

taskNode :: T.Text -> T.Text -> CircuitTaskNode
taskNode nodeRef label =
  CircuitTaskNode
    { circuitTaskNodeRef = CircuitNodeRef nodeRef
    , circuitTaskNodeLabel = label
    , circuitTaskNodeKind = Nothing
    , circuitTaskNodeMetadata = Aeson.object []
    }

pulseConfig :: CircuitPulseConfig
pulseConfig =
  CircuitPulseConfig
    { circuitPulseInitialState = Aeson.object []
    , circuitPulseRuntimeVersion = 1
    , circuitPulseReplayPolicy = ReplayPolicyWarn
    , circuitPulseInitialRewriteBudget = defaultRewriteBudget
    , circuitPulseRewriteExhaustionPolicy = RewriteExhaustionFail
    , circuitPulseBudgetExceededExhaustionPolicy = Nothing
    , circuitPulseMaxRewriteReExecutions = 2
    }

defaultBinder :: CircuitPulseBinder
defaultBinder =
  CircuitPulseBinder
    { bindCircuitTaskNode = pure . passThroughStageDefinition . circuitNodeId . (.circuitTaskNodeRef)
    , bindCircuitSignalBoundary =
        pure . passThroughStageDefinition . circuitNodeId . (.circuitSignalBoundaryRef)
    , bindCircuitArtifactBoundary =
        pure . passThroughStageDefinition . circuitNodeId . (.circuitArtifactBoundaryRef)
    , bindCircuitRewriteBoundary =
        pure . passThroughStageDefinition . circuitNodeId . (.circuitRewriteBoundaryRef)
    , bindCircuitConditionNode = const (Right (conditionBinding CircuitConditionThen (Aeson.Bool True)))
    }

mismatchedBinder :: CircuitPulseBinder
mismatchedBinder =
  defaultBinder
    { bindCircuitTaskNode =
        \task ->
          pure . passThroughStageDefinition $
            case task.circuitTaskNodeRef of
              CircuitNodeRef "planner" -> NodeId "planner:mismatch"
              ref -> circuitNodeId ref
    }

thenBranchBinder :: CircuitPulseBinder
thenBranchBinder = defaultBinder

elseBranchBinder :: CircuitPulseBinder
elseBranchBinder =
  defaultBinder
    { bindCircuitConditionNode = const (Right (conditionBinding CircuitConditionElse (Aeson.Bool False)))
    }

circuitNodeId :: CircuitNodeRef -> NodeId
circuitNodeId (CircuitNodeRef refText) = NodeId refText

passThroughStageDefinition :: NodeId -> StageDefinition NodeId
passThroughStageDefinition stageRef =
  StageDefinition
    { sdStageId = stageRef
    , sdTemplateId = stageTemplateId stageRef
    , sdActionId = stageActionId stageRef
    , sdReplaySafety = SafeToReplay
    , sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , sdRetryPolicy = Nothing
    , sdAction = liftChainAction (\_ state -> pure state)
    , sdMemoryStrategy = defaultMemoryStrategy
    }

conditionBinding :: CircuitConditionBranch -> Aeson.Value -> CircuitConditionBinding
conditionBinding branch output =
  CircuitConditionBinding
    { circuitConditionReplaySafety = SafeToReplay
    , circuitConditionReplayPolicyOverride = Nothing
    , circuitConditionTimeoutSeconds = Nothing
    , circuitConditionRetryPolicy = Nothing
    , circuitConditionTemplateId = Nothing
    , circuitConditionActionId = Nothing
    , circuitConditionSelectBranch = \_ _ ->
        pure
          CircuitConditionSelection
            { circuitConditionSelectionOutput = output
            , circuitConditionSelectionBranch = branch
            }
    }
