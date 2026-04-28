{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.CompileSpec (spec) where

import Cortex.Algebra.Graph (successors)
import Cortex.Wire.Circuit.Artifact
  ( CircuitConditionNode (..),
    CompiledCircuit (..),
    CompiledCircuitFragment (..),
    CompiledCircuitNode (..),
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Compile (compileWireFragmentText, compileWireText)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = describe "Cortex.Wire.Compile" $ do
  it "compiles a minimal canonical Wire chain through the compiled circuit backend" $ do
    compiled <- requireRight (compileWireText simpleChainSourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "planner"]
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "analyst"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "planner")
      `shouldBe` Set.singleton (CircuitNodeRef "analyst")

  it "treats a top-level comma file-return as overlay shorthand" $ do
    compiled <- requireRight (compileWireFragmentText commaOverlayFragmentSourceText)
    Set.fromList compiled.compiledCircuitEntryNodes
      `shouldBe` Set.fromList [CircuitNodeRef "stress_alpha", CircuitNodeRef "stress_beta"]
    Set.fromList compiled.compiledCircuitExitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "stress_alpha", CircuitNodeRef "stress_beta"]

  it "compiles a bare @llm executor reference without crashing" $ do
    compiled <- requireRight (compileWireText bareLlmSourceText)
    case Map.lookup (CircuitNodeRef "planner") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        case taskNode.circuitTaskNodeMetadata of
          Aeson.Object obj ->
            KeyMap.lookup "executor" obj
              `shouldBe` Just
                (Aeson.object ["kind" Aeson..= ("native" :: T.Text), "target" Aeson..= ("llm" :: T.Text)])
          other ->
            expectationFailure ("expected object metadata, got: " <> show other)
      other ->
        expectationFailure ("expected compiled task node, got: " <> show other)

  it "compiles a wrapper-bearing Wire file and lifts runtime-wrapper metadata" $ do
    compiled <- requireRight (compileWireText wrapperSourceText)
    compiled.compiledCircuitId `shouldBe` "wrapper_smoke"
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "__runtime_wrapper:0"]
    Map.member (CircuitNodeRef "__runtime_wrapper:0") compiled.compiledCircuitNodes
      `shouldBe` True
    compiled.compiledCircuitMetadata `shouldSatisfy` \case
      Aeson.Object obj ->
        KeyMap.lookup "defaultReportTitle" obj == Just (Aeson.String "Wrapper Smoke")
          && KeyMap.lookup "displayDescription" obj
            == Just (Aeson.String "Checks metadata lifting through @cortex.deep_report.")
      _ -> False

  it "compiles binary select(...) into a latent condition node over the shared continuation" $ do
    compiled <- requireRight (compileWireText selectSourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "draft_plan"]
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "publish_report"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "draft_plan")
      `shouldBe` Set.singleton (CircuitNodeRef "validate_plan")
    let maybeSelectNode =
          filter
            (\(_, node) -> case node of CompiledCircuitCondition {} -> True; _ -> False)
            (Map.toList compiled.compiledCircuitNodes)
    length maybeSelectNode `shouldBe` 1
    case maybeSelectNode of
      [(selectRef, CompiledCircuitCondition conditionNode)] -> do
        successors compiled.compiledCircuitTopology (CircuitNodeRef "validate_plan")
          `shouldBe` Set.singleton selectRef
        successors compiled.compiledCircuitTopology selectRef
          `shouldBe` Set.singleton (CircuitNodeRef "publish_report")
        case conditionNode.circuitConditionNodeMetadata of
          Aeson.Object obj -> do
            KeyMap.lookup "kind" obj `shouldBe` Just (Aeson.String "wire_select")
            KeyMap.lookup "selectorMode" obj `shouldBe` Just (Aeson.String "exclusive_output")
            KeyMap.lookup "selector" obj
              `shouldBe` Just
                ( Aeson.toJSON
                    [ Aeson.object
                        [ "node" Aeson..= ("validate_plan" :: T.Text),
                          "port" Aeson..= ("ResearchPlan_1" :: T.Text),
                          "contract" Aeson..= ("ResearchPlan" :: T.Text),
                          "label" Aeson..= Aeson.Null
                        ],
                      Aeson.object
                        [ "node" Aeson..= ("validate_plan" :: T.Text),
                          "port" Aeson..= ("PlanIssue_2" :: T.Text),
                          "contract" Aeson..= ("PlanIssue" :: T.Text),
                          "label" Aeson..= Aeson.Null
                        ]
                    ]
                )
          other ->
            expectationFailure ("expected object select metadata, got: " <> show other)
        conditionNode.circuitConditionNodeElseFragment `shouldBe` Nothing
        Map.keys conditionNode.circuitConditionNodeThenFragment.compiledCircuitFragmentNodes
          `shouldBe` [CircuitNodeRef "gather_missing_constraints", CircuitNodeRef "repair_plan"]
      other ->
        expectationFailure ("expected one compiled select condition node, got: " <> show other)

  it "compiles bare select(...) in tail position and leaves the select node as the exit" $ do
    compiled <- requireRight (compileWireText bareSelectSourceText)
    let maybeSelectNode =
          filter
            (\(_, node) -> case node of CompiledCircuitCondition {} -> True; _ -> False)
            (Map.toList compiled.compiledCircuitNodes)
    case maybeSelectNode of
      [(selectRef, CompiledCircuitCondition conditionNode)] -> do
        compiled.compiledCircuitExitNodes `shouldBe` [selectRef]
        successors compiled.compiledCircuitTopology (CircuitNodeRef "validate_plan")
          `shouldBe` Set.singleton selectRef
        conditionNode.circuitConditionNodeElseFragment `shouldBe` Nothing
      other ->
        expectationFailure ("expected one compiled tail-position select condition node, got: " <> show other)

  it "compiles n-way select(...) by lowering to nested binary latent condition nodes" $ do
    compiled <- requireRight (compileWireText nWaySelectSourceText)
    let liveSelectNodes =
          filter
            (\(_, node) -> case node of CompiledCircuitCondition {} -> True; _ -> False)
            (Map.toList compiled.compiledCircuitNodes)
    length liveSelectNodes `shouldBe` 1
    case liveSelectNodes of
      [(_, CompiledCircuitCondition conditionNode)] -> do
        fragmentContainsCondition conditionNode.circuitConditionNodeThenFragment
          `shouldBe` True
      other ->
        expectationFailure ("expected one live n-way select condition node, got: " <> show other)

simpleChainSourceText :: T.Text
simpleChainSourceText =
  T.unlines
    [ "node planner : -> PlannerOutput = @llm.planner {};",
      "node analyst : <- PlannerOutput -> AnalysisFragment = @llm.analyst {};",
      "",
      "planner => analyst"
    ]

commaOverlayFragmentSourceText :: T.Text
commaOverlayFragmentSourceText =
  T.unlines
    [ "node stress_alpha : -> AnalysisFragment = @llm.alpha {};",
      "node stress_beta : -> AnalysisFragment = @llm.beta {};",
      "",
      "stress_alpha, stress_beta"
    ]

bareLlmSourceText :: T.Text
bareLlmSourceText =
  T.unlines
    [ "node planner : -> PlannerOutput = @llm {};",
      "",
      "planner"
    ]

wrapperSourceText :: T.Text
wrapperSourceText =
  T.unlines
    [ "let analyst_base = @llm.analyst {",
      "  memory = topological { preset = \"analyst\"; };",
      "};",
      "",
      "node planner : -> PlannerOutput = @llm.planner {};",
      "node analyst : <- PlannerOutput -> AnalysisFragment = analyst_base;",
      "",
      "planner => analyst => @cortex.deep_report {",
      "  title = \"Wrapper Smoke\";",
      "  description = \"Checks metadata lifting through @cortex.deep_report.\";",
      "  match.skill = \"deep-report\";",
      "  match.priority = 1;",
      "  render.aggregateOpenGaps = true;",
      "  workspace.sourceKind = \"deep-report\";",
      "}"
    ]

selectSourceText :: T.Text
selectSourceText =
  T.unlines
    [ "node draft_plan : -> DraftPlan = @llm.plan {};",
      "node validate_plan : <- DraftPlan -> ResearchPlan | PlanIssue = @llm.validate_plan {};",
      "node gather_missing_constraints : <- PlanIssue -> PlanIssue = @llm.gather_missing_constraints {};",
      "node repair_plan : <- PlanIssue -> ResearchPlan = @llm.repair_plan {};",
      "node publish_report : <- ResearchPlan -> ReportArtifactRef = @artifact.publish_report {};",
      "",
      "draft_plan => validate_plan select(",
      "  ResearchPlan: (),",
      "  PlanIssue: (gather_missing_constraints => repair_plan)",
      ") => publish_report"
    ]

bareSelectSourceText :: T.Text
bareSelectSourceText =
  T.unlines
    [ "node validate_plan : <- DraftPlan -> ResearchPlan | PlanIssue = @llm.validate_plan {};",
      "node gather_missing_constraints : <- PlanIssue -> PlanIssue = @llm.gather_missing_constraints {};",
      "node repair_plan : <- PlanIssue -> ResearchPlan = @llm.repair_plan {};",
      "",
      "validate_plan select(",
      "  ResearchPlan: (),",
      "  PlanIssue: (gather_missing_constraints => repair_plan)",
      ")"
    ]

nWaySelectSourceText :: T.Text
nWaySelectSourceText =
  T.unlines
    [ "node draft_plan : -> DraftPlan = @llm.plan {};",
      "node classify_plan : <- DraftPlan -> ResearchPlan | MinorIssue | MajorIssue = @llm.classify_plan {};",
      "node minor_repair : <- MinorIssue -> ResearchPlan = @llm.minor_repair {};",
      "node gather_major_context : <- MajorIssue -> MajorIssue = @llm.gather_major_context {};",
      "node major_repair : <- MajorIssue -> ResearchPlan = @llm.major_repair {};",
      "node publish_report : <- ResearchPlan -> ReportArtifactRef = @artifact.publish_report {};",
      "",
      "draft_plan => classify_plan select(",
      "  ResearchPlan: (),",
      "  MinorIssue: minor_repair,",
      "  MajorIssue: (gather_major_context => major_repair)",
      ") => publish_report"
    ]

requireRight :: (Show err) => Either err a -> IO a
requireRight = \case
  Left err -> expectationFailure ("expected Right, got Left: " <> show err) >> error "unreachable"
  Right ok -> pure ok

fragmentContainsCondition :: CompiledCircuitFragment -> Bool
fragmentContainsCondition fragment =
  any isConditionNode (Map.elems fragment.compiledCircuitFragmentNodes)
  where
    isConditionNode = \case
      CompiledCircuitCondition {} -> True
      _ -> False
