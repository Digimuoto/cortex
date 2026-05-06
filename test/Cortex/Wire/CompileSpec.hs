{- |
Module      : Cortex.Wire.CompileSpec
Description : Tests for Cortex.Wire.Compile.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.CompileSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Algebra.Graph (successors)
import Cortex.Wire (WirePayloadKind (..))
import Cortex.Wire.Circuit.Artifact
  ( CircuitConditionNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Compile
  ( compileWireFragmentText
  , compileWireText
  , compileWireTextWithEnv
  , compileWireTextWithReturn
  )
import Cortex.Wire.Contract
  ( WireCompileEnv (..)
  , WireContractSpec (..)
  , WireProjectionMode (..)
  , emptyWireCompileEnv
  , wireContractRegistryFromList
  )
import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , wireExecutorProjectionFromPorts
  , wireExecutorRegistryFromList
  )
import Cortex.Wire.Pure (pureWireExecutorProjection)
import Cortex.Wire.Std
  ( stdIoReadFileShapeMessage
  , stdIoStdoutShapeMessage
  , stdIoWriteFileShapeMessage
  )
import Cortex.Wire.Syntax (WireError (..), WireOutputPort (..), WirePorts (..))

spec :: Spec
spec = describe "Cortex.Wire.Compile" $ do
  it "compiles a labeled Wire chain through the compiled circuit backend" $ do
    compiled <- requireRight (compileWireText simpleChainSourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "planner"]
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "analyst"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "planner")
      `shouldBe` Set.singleton (CircuitNodeRef "analyst")

  it "compiles explicit overlay with independent entries and exits" $ do
    compiled <- requireRight (compileWireFragmentText overlayFragmentSourceText)
    Set.fromList compiled.compiledCircuitEntryNodes
      `shouldBe` Set.fromList [CircuitNodeRef "stress_alpha", CircuitNodeRef "stress_beta"]
    Set.fromList compiled.compiledCircuitExitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "stress_alpha", CircuitNodeRef "stress_beta"]

  it "compiles a configured executor value applied in a node body" $ do
    compiled <- requireRight (compileWireText configuredExecutorSourceText)
    case Map.lookup (CircuitNodeRef "analyst") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataConfigHasNumber "temperature" 0.2
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles node-body kind applications into ordinary nodes" $ do
    compiled <- requireRight (compileWireText kindApplicationSourceText)
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "screen_h")
    case Map.lookup (CircuitNodeRef "screen_h") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataConfigHasNumber "angle" 1.25
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles graph forms with fresh scoped node identities" $ do
    compiled <- requireRight (compileWireText graphFormSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "pipeline/first", CircuitNodeRef "pipeline/second"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "pipeline/first")
      `shouldBe` Set.singleton (CircuitNodeRef "pipeline/second")

  it "passes graph values into graph forms without cloning captured nodes" $ do
    compiled <- requireRight (compileWireText graphFormGraphParamSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "source", CircuitNodeRef "pipeline/tail"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "source")
      `shouldBe` Set.singleton (CircuitNodeRef "pipeline/tail")

  it "evaluates top-level pure-data lets in executor config" $ do
    compiled <- requireRight (compileWireText topLevelLetConfigSourceText)
    case Map.lookup (CircuitNodeRef "analyst") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasInstructions "Audit now"
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles graph-valued top-level let bindings" $ do
    compiled <- requireRight (compileWireText graphLetSourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "planner"]
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "analyst"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "planner")
      `shouldBe` Set.singleton (CircuitNodeRef "analyst")

  it "allows exported graph libraries outside the default file return" $ do
    compiled <- requireRight (compileWireText exportedGraphLibrarySourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "main"]
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "main")

  it "compiles a selected graph-valued return" $ do
    compiled <- requireRight (compileWireTextWithReturn "library_graph" exportedGraphLibrarySourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "library"]
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "library")

  it "lowers executor where records into executor config" $ do
    compiled <- requireRight (compileWireText executorWhereSourceText)
    case Map.lookup (CircuitNodeRef "analyze") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataConfigHasKey "where"
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles a zero-output executor body as a node with an empty output boundary" $ do
    compiled <- requireRight (compileWireText zeroOutputSourceText)
    case Map.lookup (CircuitNodeRef "log_event") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        case taskNode.circuitTaskNodeMetadata of
          Aeson.Object obj ->
            case KeyMap.lookup "ports" obj of
              Just (Aeson.Object portsObj) ->
                KeyMap.lookup "outputs" portsObj `shouldBe` Just (Aeson.Array mempty)
              other -> expectationFailure ("unexpected ports metadata: " <> show other)
          other -> expectationFailure ("unexpected metadata: " <> show other)
      other -> expectationFailure ("expected task node, got: " <> show other)

  it "compiles select(...) over a labeled exclusive output boundary" $ do
    compiled <- requireRight (compileWireText selectSourceText)
    let conditionNodes =
          filter
            (\(_, node) -> case node of CompiledCircuitCondition {} -> True; _ -> False)
            (Map.toList compiled.compiledCircuitNodes)
    length conditionNodes `shouldBe` 1
    case conditionNodes of
      [(selectRef, CompiledCircuitCondition conditionNode)] -> do
        successors compiled.compiledCircuitTopology (CircuitNodeRef "validate_plan")
          `shouldBe` Set.singleton selectRef
        conditionNode.circuitConditionNodeElseFragment `shouldBe` Nothing
      other ->
        expectationFailure ("expected one condition node, got: " <> show other)

  describe "contract declarations" $ do
    it "accepts registered contracts under an explicit registry" $
      compileWireTextWithEnv knownContractsEnv simpleChainSourceText
        `shouldSatisfy` isRight

    it "accepts file-local contract declarations under an explicit registry" $
      compileWireTextWithEnv
        knownContractsEnv
        ( T.unlines
            [ "contract LocalOnly;"
            , "node local"
            , "  -> out: LocalOnly = @review.local ({}) ;"
            , "local"
            ]
        )
        `shouldSatisfy` isRight

    it "rejects undeclared contract typos under an explicit registry" $
      compileWireTextWithEnv knownContractsEnv typoContractSourceText
        `shouldBe` Left (WireUnknownContract "node ports" "PlannerOuput")

  describe "executor projections" $ do
    it "allows a strict registered executor projection with matching ports" $
      compileWireTextWithEnv strictExecutorEnv projectedExecutorSourceText
        `shouldSatisfy` isRight

    it "rejects a missing executor in strict projection mode" $
      compileWireTextWithEnv strictExecutorEnv missingExecutorSourceText
        `shouldBe` Left (WireUnknownExecutor (CircuitNodeRef "missing") "review.missing")

    it "rejects mismatched ports in strict projection mode" $
      compileWireTextWithEnv strictExecutorEnv mismatchedExecutorPortsSourceText
        `shouldBe` Left (WireExecutorPortsMismatch (CircuitNodeRef "projected") "review.projected")

    it "allows author-declared ports for the pure executor in strict projection mode" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorSourceText
        `shouldSatisfy` isRight

    it "lowers top-level CorePure helpers into pure node config" $ do
      compiled <-
        requireRight (compileWireTextWithEnv strictExecutorEnv pureExecutorWithSharedHelperSourceText)
      case Map.lookup (CircuitNodeRef "classify") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureBinding "acceptedItem"
        other ->
          expectationFailure ("expected compiled pure task node, got: " <> show other)

    it "captures top-level pure-data lets into pure node config" $ do
      compiled <-
        requireRight (compileWireTextWithEnv strictExecutorEnv pureExecutorWithScalarLetSourceText)
      case Map.lookup (CircuitNodeRef "classify") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureBinding "scoreThreshold"
        other ->
          expectationFailure ("expected compiled pure task node, got: " <> show other)

    it "lowers node-local where records and port-keyed output equations" $ do
      compiled <-
        requireRight (compileWireTextWithEnv strictExecutorEnv pureExecutorWithLocalBindingsSourceText)
      case Map.lookup (CircuitNodeRef "classify") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) -> do
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureBinding "acceptedItem"
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureWhere
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureOutput "accepted"
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureOutput "rejected"
        other ->
          expectationFailure ("expected compiled pure task node, got: " <> show other)

    it "accepts let-bound where records with statically known fields" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorWithLetBoundWhereSourceText
        `shouldSatisfy` isRight

    it "rejects node-local where lets that shadow statically known records" $
      compileWireTextWithEnv strictExecutorEnv whereLocalLetShadowsStaticSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "classify")
              "where-clause local let binding shadows static binding defaults"
          )

    it "rejects where fields that collide with input ports" $
      compileWireTextWithEnv strictExecutorEnv whereInputCollisionSourceText
        `shouldBe` Left (WireInvalidPorts (CircuitNodeRef "classify") "where field collides with input port evidence")

    it "rejects where field sets that are not statically determinable" $
      compileWireTextWithEnv strictExecutorEnv whereDynamicShapeSourceText
        `shouldBe` Left
          (WireInvalidPorts (CircuitNodeRef "classify") "where-clause field set is not statically determinable")

    it "rejects duplicate CorePure record paths during compiler lowering" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorDuplicateRecordPathSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "score")
              "Pure record literal declares conflicting field paths a and a."
          )

    it "rejects prefix-conflicting CorePure record paths during compiler lowering" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorPrefixRecordPathSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "score")
              "Pure record literal declares conflicting field paths a.b and a."
          )

    it "rejects duplicate names across CorePure helpers and ordinary value lets" $
      compileWireTextWithEnv strictExecutorEnv duplicatePureAndWireLetSourceText
        `shouldBe` Left (WireDuplicateLetBinding "acceptedItem")

    it "rejects authored @pure executor applications" $
      compileWireTextWithEnv strictExecutorEnv legacyPureExecutorSourceText
        `shouldSatisfy` isParseFailure

    it "rejects configured executor values inside CorePure output equations" $
      compileWireText configuredExecutorInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "configured executor analyst_base"

    it "rejects graph values inside CorePure output equations" $
      compileWireText graphBindingInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "graph value workers"

    it "rejects node values inside CorePure output equations" $
      compileWireText nodeBindingInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "node value worker"

    it "rejects imported executors inside CorePure output equations" $
      compileWireText importedExecutorInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "imported executor command"

    it "rejects contracts inside CorePure output equations" $
      compileWireText contractInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "contract AcceptedSet"

    it "rejects non-CorePure captures inside top-level CorePure lets" $
      compileWireText graphBindingInTopLevelCorePureLetSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "graph value workers"

  describe "namespace use imports" $ do
    it "lowers std.io aliases to canonical executor and contract IDs" $ do
      compiled <- requireRight (compileWireText stdIoAliasSourceText)
      case Map.lookup (CircuitNodeRef "run") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) -> do
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasExecutorTarget "std.io.command"
          taskNode.circuitTaskNodeMetadata
            `shouldSatisfy` metadataHasInputContract "spec" "std.io.CommandSpec.v1"
          taskNode.circuitTaskNodeMetadata
            `shouldSatisfy` metadataHasOutputContract "result" "std.io.CommandResult.v1"
        other ->
          expectationFailure ("expected task node, got: " <> show other)

    it "allows canonical std.io executor references after use" $
      compileWireText stdIoCanonicalAfterUseSourceText
        `shouldSatisfy` isRight

    it "rejects bare std.io executor leaves without use" $
      compileWireText stdIoBareWithoutUseSourceText
        `shouldBe` Left (WireExecutorNotInScope "@command")

    it "rejects canonical std.io executor references without use" $
      compileWireText stdIoCanonicalWithoutUseSourceText
        `shouldBe` Left (WireExecutorNotInScope "@std.io.command")

    it "rejects use names that collide with local contracts" $
      compileWireText stdIoUseContractCollisionSourceText
        `shouldBe` Left (WireDuplicateBinding "CommandSpec")

    it "enforces standard stdout port shape" $
      compileWireText stdIoStdoutBadShapeSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "bad_stdout")
              stdIoStdoutShapeMessage
          )

    it "lowers std.io file executors" $ do
      compiled <- requireRight (compileWireText stdIoFileExecutorsSourceText)
      case Map.lookup (CircuitNodeRef "read_report") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasExecutorTarget "std.io.readFile"
        other ->
          expectationFailure ("expected read_report task node, got: " <> show other)
      case Map.lookup (CircuitNodeRef "write_report") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasExecutorTarget "std.io.writeFile"
        other ->
          expectationFailure ("expected write_report task node, got: " <> show other)

    it "enforces standard readFile port shape" $
      compileWireText stdIoReadFileBadShapeSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "bad_read")
              stdIoReadFileShapeMessage
          )

    it "enforces standard writeFile port shape" $
      compileWireText stdIoWriteFileBadShapeSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "bad_write")
              stdIoWriteFileShapeMessage
          )

  describe "fixtures" $ do
    it "compiles the interactive priority planner example" $ do
      source <- TIO.readFile "examples/wire/interactive-priority-planner.wire"
      compileWireText source `shouldSatisfy` isRight

    it "compiles the mini build-system example" $ do
      source <- TIO.readFile "examples/wire/mini-build-system.wire"
      compileWireText source `shouldSatisfy` isRight

    it "compiles the quantum Bell-state example with consumer executor projections" $ do
      source <- TIO.readFile "examples/wire/quantum-bell-state.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList [CircuitNodeRef "prepare_control", CircuitNodeRef "prepare_target"]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "measure_control", CircuitNodeRef "measure_target"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "entangle")
        `shouldBe` Set.fromList [CircuitNodeRef "measure_control", CircuitNodeRef "measure_target"]

    it "compiles the IBM REST quantum Bell-state example with a config node" $ do
      source <- TIO.readFile "examples/wire/quantum-bell-state-ibm-rest.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList
          [ CircuitNodeRef "ibm_runtime_config"
          , CircuitNodeRef "prepare_target"
          ]
      case Map.lookup (CircuitNodeRef "ibm_runtime_config") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata
            `shouldSatisfy` metadataConfigHasString
              "path"
              "quantum-ibm-runtime.local.json"
        other ->
          expectationFailure ("expected task node, got: " <> show other)

    it "compiles the quantum IPEA round example with primitive executors" $ do
      source <- TIO.readFile "examples/wire/quantum-ipea-round.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList
          [ CircuitNodeRef "ibm_runtime_config"
          , CircuitNodeRef "prepare_target"
          ]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "measure_phase"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "phase_rzz")
        `shouldBe` Set.fromList [CircuitNodeRef "feedback_control_rz"]

    it "compiles the quantum eraser round example with primitive executors" $ do
      source <- TIO.readFile "examples/wire/quantum-eraser-round.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList
          [ CircuitNodeRef "ibm_runtime_config"
          , CircuitNodeRef "prepare_marker"
          ]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "measure_screen", CircuitNodeRef "z_measure_marker"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "mark_cz")
        `shouldBe` Set.fromList
          [ CircuitNodeRef "recombine_rz_a"
          , CircuitNodeRef "z_mark_post_rz_a"
          ]

    it "compiles the full quantum eraser experiment scaffold" $ do
      source <- TIO.readFile "examples/wire/quantum-eraser-experiment.wire"
      compiled <- requireRight (compileWireText source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList [CircuitNodeRef "start_experiment"]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "print_report", CircuitNodeRef "write_report"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "run_open_0")
        `shouldBe` Set.fromList [CircuitNodeRef "gate_open_14", CircuitNodeRef "summarize_experiment"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "gate_open_14")
        `shouldBe` Set.fromList [CircuitNodeRef "run_open_14"]

    it "compiles the quantum eraser sweep circuit examples with primitive executors" $
      mapM_ compileQuantumEraserFixture quantumEraserSweepFixtures

    it "compiles the pure output equations fixture" $ do
      source <- TIO.readFile "test/fixtures/wire/pure-output-equations.wire"
      compileWireText source `shouldSatisfy` isRight

    it "compiles the thesis parallel claim branches fixture" $ do
      source <- TIO.readFile "test/fixtures/wire/thesis-parallel-claim-branches.wire"
      compileWireText source `shouldSatisfy` isRight

simpleChainSourceText :: T.Text
simpleChainSourceText =
  T.unlines
    [ "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment = @review.analyst (plan) ;"
    , "planner => analyst"
    ]

overlayFragmentSourceText :: T.Text
overlayFragmentSourceText =
  T.unlines
    [ "node stress_alpha"
    , "  -> fragment: AnalysisFragment = @review.alpha ({}) ;"
    , "node stress_beta"
    , "  -> fragment: AnalysisFragment = @review.beta ({}) ;"
    , "(stress_alpha) <> (stress_beta)"
    ]

configuredExecutorSourceText :: T.Text
configuredExecutorSourceText =
  T.unlines
    [ "let analyst_base = @review.analyst { temperature = 0.2 ; } ;"
    , "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment ;"
    , "  = analyst_base (plan) ;"
    , "planner => analyst"
    ]

kindApplicationSourceText :: T.Text
kindApplicationSourceText =
  T.unlines
    [ "kind phase_gate(label: PortLabel, portContract: Contract, angle: Value) ="
    , "  <- label: portContract ;"
    , "  -> label: portContract = @quantum.rz { angle = angle ; } (label) ;"
    , "node screen_h = phase_gate(screen, Qubit, 1.25);"
    , "screen_h"
    ]

graphFormSourceText :: T.Text
graphFormSourceText =
  T.unlines
    [ "kind phase_gate(label: PortLabel, portContract: Contract, angle: Value) ="
    , "  <- label: portContract ;"
    , "  -> label: portContract = @quantum.rz { angle = angle ; } (label) ;"
    , "form two_phases(angle: Value) = {"
    , "  node first = phase_gate(screen, Qubit, angle);"
    , "  node second = phase_gate(screen, Qubit, angle);"
    , "  first => second;"
    , "};"
    , "let pipeline = two_phases(1.25);"
    , "pipeline"
    ]

graphFormGraphParamSourceText :: T.Text
graphFormGraphParamSourceText =
  T.unlines
    [ "node source"
    , "  -> out: T = @review.source ({}) ;"
    , "form append_tail(head: Graph) = {"
    , "  node tail"
    , "    <- out: T ;"
    , "    -> done: U = @review.tail (out) ;"
    , "  head => tail;"
    , "};"
    , "let base = source;"
    , "let pipeline = append_tail(base);"
    , "pipeline"
    ]

topLevelLetConfigSourceText :: T.Text
topLevelLetConfigSourceText =
  T.unlines
    [ "let prefix = \"Audit \" ;"
    , "let suffix = \"now\" ;"
    , "let analyst_instructions = prefix ++ suffix ;"
    , "let analyst_base = @review.analyst { instructions = analyst_instructions ; } ;"
    , "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment ;"
    , "  = analyst_base (plan) ;"
    , "planner => analyst"
    ]

graphLetSourceText :: T.Text
graphLetSourceText =
  T.unlines
    [ "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment = @review.analyst (plan) ;"
    , "let pipeline = planner => analyst ;"
    , "pipeline"
    ]

exportedGraphLibrarySourceText :: T.Text
exportedGraphLibrarySourceText =
  T.unlines
    [ "node library"
    , "  -> out: LibraryOutput = @review.library ({}) ;"
    , "node main"
    , "  -> out: MainOutput = @review.main ({}) ;"
    , "export let library_graph = library ;"
    , "main"
    ]

zeroOutputSourceText :: T.Text
zeroOutputSourceText =
  T.unlines
    [ "node emit"
    , "  -> event: Event = @review.event ({}) ;"
    , "node log_event"
    , "  <- event: Event ;"
    , "  = @artifact.log (event) ;"
    , "emit => log_event"
    ]

executorWhereSourceText :: T.Text
executorWhereSourceText =
  T.unlines
    [ "node analyze"
    , "  <- evidence: EvidenceSet ;"
    , "  -> analysis: AnalysisRecord ;"
    , "  = @review.analyze (payload) ;"
    , "  where { payload = { items = evidence.items ; } ; } ;"
    , "analyze"
    ]

selectSourceText :: T.Text
selectSourceText =
  T.unlines
    [ "node draft_plan"
    , "  -> draft: DraftPlan = @review.plan ({}) ;"
    , "node validate_plan"
    , "  <- draft: DraftPlan ;"
    , "  -> ok: ResearchPlan | issue: PlanIssue ;"
    , "  = @review.validate_plan (draft) ;"
    , "node gather_missing_constraints"
    , "  <- issue: PlanIssue ;"
    , "  -> issue: PlanIssue = @review.gather_missing_constraints (issue) ;"
    , "node repair_plan"
    , "  <- issue: PlanIssue ;"
    , "  -> ok: ResearchPlan = @review.repair_plan (issue) ;"
    , "node publish_report"
    , "  <- ok: ResearchPlan ;"
    , "  -> report: ReportArtifactRef = @artifact.publish_report (ok) ;"
    , "draft_plan => validate_plan select("
    , "  ok: (),"
    , "  issue: (gather_missing_constraints => repair_plan)"
    , ") => publish_report"
    ]

typoContractSourceText :: T.Text
typoContractSourceText =
  T.unlines
    [ "node planner"
    , "  -> plan: PlannerOuput = @review.planner ({}) ;"
    , "planner"
    ]

projectedExecutorSourceText :: T.Text
projectedExecutorSourceText =
  T.unlines
    [ "node projected"
    , "  -> out: PlannerOutput = @review.projected ({}) ;"
    , "projected"
    ]

missingExecutorSourceText :: T.Text
missingExecutorSourceText =
  T.unlines
    [ "node missing"
    , "  -> out: PlannerOutput = @review.missing ({}) ;"
    , "missing"
    ]

mismatchedExecutorPortsSourceText :: T.Text
mismatchedExecutorPortsSourceText =
  T.unlines
    [ "node projected"
    , "  -> out: AnalysisFragment = @review.projected ({}) ;"
    , "projected"
    ]

pureExecutorSourceText :: T.Text
pureExecutorSourceText =
  T.unlines
    [ "node score"
    , "  <- evidence: Float ;"
    , "  <- recency: Float ;"
    , "  -> out: Float = evidence + recency ;"
    , "score"
    ]

pureExecutorWithSharedHelperSourceText :: T.Text
pureExecutorWithSharedHelperSourceText =
  T.unlines
    [ "let acceptedItem = x: x.score >= 0.7 ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = evidence.items |> filter acceptedItem ;"
    , "classify"
    ]

pureExecutorWithScalarLetSourceText :: T.Text
pureExecutorWithScalarLetSourceText =
  T.unlines
    [ "let scoreThreshold = 0.7 ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = evidence.items |> filter (x: x.score >= scoreThreshold) ;"
    , "classify"
    ]

pureExecutorWithLocalBindingsSourceText :: T.Text
pureExecutorWithLocalBindingsSourceText =
  T.unlines
    [ "let acceptedItem = x: x.score >= 0.7 ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = acceptedItems ;"
    , "  -> rejected: RejectedSet = items |> filter (x: !(acceptedItem x)) ;"
    , "  where let"
    , "    items = evidence.items ;"
    , "    acceptedItems = items |> filter acceptedItem ;"
    , "  in"
    , "  { items = items ; acceptedItems = acceptedItems ; } ;"
    , "classify"
    ]

pureExecutorWithLetBoundWhereSourceText :: T.Text
pureExecutorWithLetBoundWhereSourceText =
  T.unlines
    [ "let defaults = { accepted = [] ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where defaults ;"
    , "classify"
    ]

whereLocalLetShadowsStaticSourceText :: T.Text
whereLocalLetShadowsStaticSourceText =
  T.unlines
    [ "let defaults = { accepted = [] ; rejected = [] ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where let"
    , "    defaults = { accepted = evidence.items ; } ;"
    , "  in"
    , "  defaults ;"
    , "classify"
    ]

whereInputCollisionSourceText :: T.Text
whereInputCollisionSourceText =
  T.unlines
    [ "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where { evidence = evidence.items ; accepted = [] ; } ;"
    , "classify"
    ]

whereDynamicShapeSourceText :: T.Text
whereDynamicShapeSourceText =
  T.unlines
    [ "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where if true then { accepted = [] ; } else { rejected = [] ; } ;"
    , "classify"
    ]

pureExecutorDuplicateRecordPathSourceText :: T.Text
pureExecutorDuplicateRecordPathSourceText =
  T.unlines
    [ "node score"
    , "  -> out: Float = if false then { a = 1 ; a = 2 ; } else 0 ;"
    , "score"
    ]

pureExecutorPrefixRecordPathSourceText :: T.Text
pureExecutorPrefixRecordPathSourceText =
  T.unlines
    [ "node score"
    , "  -> out: Float = if false then { a.b = 1 ; a = 2 ; } else 0 ;"
    , "score"
    ]

duplicatePureAndWireLetSourceText :: T.Text
duplicatePureAndWireLetSourceText =
  T.unlines
    [ "let acceptedItem = x: x.score >= 0.7 ;"
    , "let acceptedItem = @review.analyst { temperature = 0.2 ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = evidence.items |> filter acceptedItem ;"
    , "classify"
    ]

legacyPureExecutorSourceText :: T.Text
legacyPureExecutorSourceText =
  T.unlines
    [ "node score"
    , "  <- evidence: Float ;"
    , "  -> out: Float = @pure (evidence) ;"
    , "score"
    ]

configuredExecutorInPureOutputSourceText :: T.Text
configuredExecutorInPureOutputSourceText =
  T.unlines
    [ "let analyst_base = @review.analyst { temperature = 0.2 ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = analyst_base(evidence) ;"
    , "classify"
    ]

graphBindingInPureOutputSourceText :: T.Text
graphBindingInPureOutputSourceText =
  T.unlines
    [ "node source"
    , "  -> evidence: EvidenceSet = @review.source ({}) ;"
    , "let workers = source ;"
    , "node classify"
    , "  -> accepted: AcceptedSet = workers ;"
    , "classify"
    ]

nodeBindingInPureOutputSourceText :: T.Text
nodeBindingInPureOutputSourceText =
  T.unlines
    [ "node worker"
    , "  -> evidence: EvidenceSet = @review.source ({}) ;"
    , "node classify"
    , "  -> accepted: AcceptedSet = worker ;"
    , "classify"
    ]

importedExecutorInPureOutputSourceText :: T.Text
importedExecutorInPureOutputSourceText =
  T.unlines
    [ "use std.io.{@command};"
    , "node classify"
    , "  -> accepted: AcceptedSet = command({}) ;"
    , "classify"
    ]

contractInPureOutputSourceText :: T.Text
contractInPureOutputSourceText =
  T.unlines
    [ "contract AcceptedSet;"
    , "node classify"
    , "  -> accepted: AcceptedSet = AcceptedSet ;"
    , "classify"
    ]

graphBindingInTopLevelCorePureLetSourceText :: T.Text
graphBindingInTopLevelCorePureLetSourceText =
  T.unlines
    [ "node source"
    , "  -> evidence: EvidenceSet = @review.source ({}) ;"
    , "let workers = source ;"
    , "let accepted = x: workers ;"
    , "node classify"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "classify"
    ]

stdIoAliasSourceText :: T.Text
stdIoAliasSourceText =
  T.unlines
    [ "use std.io.{@command as @shell, CommandSpec as Spec, CommandResult as Result};"
    , "node run"
    , "  <- spec: Spec ;"
    , "  -> result: Result = @shell {} (spec) ;"
    , "run"
    ]

stdIoCanonicalAfterUseSourceText :: T.Text
stdIoCanonicalAfterUseSourceText =
  T.unlines
    [ "use std.io.{@command, CommandResult};"
    , "node run"
    , "  -> result: CommandResult = @std.io.command {} (null) ;"
    , "run"
    ]

stdIoBareWithoutUseSourceText :: T.Text
stdIoBareWithoutUseSourceText =
  T.unlines
    [ "node run"
    , "  -> result: CommandResult = @command {} (null) ;"
    , "run"
    ]

stdIoCanonicalWithoutUseSourceText :: T.Text
stdIoCanonicalWithoutUseSourceText =
  T.unlines
    [ "node run"
    , "  -> result: CommandResult = @std.io.command {} (null) ;"
    , "run"
    ]

stdIoUseContractCollisionSourceText :: T.Text
stdIoUseContractCollisionSourceText =
  T.unlines
    [ "use std.io.{CommandSpec};"
    , "contract CommandSpec;"
    ]

stdIoStdoutBadShapeSourceText :: T.Text
stdIoStdoutBadShapeSourceText =
  T.unlines
    [ "use std.io.{@stdout};"
    , "node bad_stdout"
    , "  -> printed: Printed = @stdout {} (null) ;"
    , "bad_stdout"
    ]

stdIoFileExecutorsSourceText :: T.Text
stdIoFileExecutorsSourceText =
  T.unlines
    [ "use std.io.{@readFile, @writeFile};"
    , "contract Report;"
    , "node read_report"
    , "  -> report: Report = @readFile { path = \"/tmp/wire-report.txt\"; } (null) ;"
    , "node write_report"
    , "  <- report: Report;"
    , "  = @writeFile { path = \"/tmp/wire-report-copy.txt\"; } (report) ;"
    , "read_report => write_report"
    ]

stdIoReadFileBadShapeSourceText :: T.Text
stdIoReadFileBadShapeSourceText =
  T.unlines
    [ "use std.io.{@readFile};"
    , "node bad_read"
    , "  = @readFile { path = \"/tmp/wire-report.txt\"; } (null) ;"
    , "bad_read"
    ]

stdIoWriteFileBadShapeSourceText :: T.Text
stdIoWriteFileBadShapeSourceText =
  T.unlines
    [ "use std.io.{@writeFile};"
    , "contract Report;"
    , "node bad_write"
    , "  <- report: Report;"
    , "  -> written: Report = @writeFile { path = \"/tmp/wire-report.txt\"; } (report) ;"
    , "bad_write"
    ]

requireRight :: Show err => Either err a -> IO a
requireRight = \case
  Left err -> expectationFailure ("expected Right, got Left: " <> show err) >> error "unreachable"
  Right ok -> pure ok

compileQuantumEraserFixture :: FilePath -> Expectation
compileQuantumEraserFixture path = do
  source <- TIO.readFile path
  compileWireTextWithEnv quantumExecutorEnv source `shouldSatisfy` isRight

quantumEraserSweepFixtures :: [FilePath]
quantumEraserSweepFixtures =
  [ "examples/wire/quantum-eraser-open-phase-0.wire"
  , "examples/wire/quantum-eraser-open-phase-1_4.wire"
  , "examples/wire/quantum-eraser-open-phase-1_2.wire"
  , "examples/wire/quantum-eraser-which-path-phase-0.wire"
  , "examples/wire/quantum-eraser-which-path-phase-1_4.wire"
  , "examples/wire/quantum-eraser-which-path-phase-1_2.wire"
  , "examples/wire/quantum-eraser-eraser-phase-1_4.wire"
  , "examples/wire/quantum-eraser-eraser-phase-1_2.wire"
  ]

metadataConfigHasNumber :: Key.Key -> ScientificLiteral -> Aeson.Value -> Bool
metadataConfigHasNumber fieldName expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        KeyMap.lookup fieldName configObj == Just (Aeson.Number expected)
      _ -> False
  _ -> False

metadataConfigHasString :: Key.Key -> T.Text -> Aeson.Value -> Bool
metadataConfigHasString fieldName expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        KeyMap.lookup fieldName configObj == Just (Aeson.String expected)
      _ -> False
  _ -> False

metadataConfigHasKey :: Key.Key -> Aeson.Value -> Bool
metadataConfigHasKey fieldName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) -> KeyMap.member fieldName configObj
      _ -> False
  _ -> False

type ScientificLiteral = Scientific

metadataHasPureBinding :: T.Text -> Aeson.Value -> Bool
metadataHasPureBinding =
  metadataHasPureBindingIn "bindings"

metadataHasPureWhere :: Aeson.Value -> Bool
metadataHasPureWhere =
  metadataConfigHasKey "where"

metadataHasPureBindingIn :: Key.Key -> T.Text -> Aeson.Value -> Bool
metadataHasPureBindingIn bindingField bindingName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        case KeyMap.lookup bindingField configObj of
          Just (Aeson.Array bindings) ->
            any (bindingHasName bindingName) bindings
          _ -> False
      _ -> False
  _ -> False
  where
    bindingHasName expectedName = \case
      Aeson.Object bindingObj ->
        KeyMap.lookup "corePureBindingName" bindingObj == Just (Aeson.String expectedName)
      _ -> False

metadataHasPureOutput :: T.Text -> Aeson.Value -> Bool
metadataHasPureOutput outputName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        case KeyMap.lookup "outputs" configObj of
          Just (Aeson.Object outputsObj) ->
            KeyMap.member (Key.fromText outputName) outputsObj
          _ -> False
      _ -> False
  _ -> False

metadataHasInstructions :: T.Text -> Aeson.Value -> Bool
metadataHasInstructions expected = \case
  Aeson.Object obj ->
    KeyMap.lookup "instructions" obj == Just (Aeson.String expected)
  _ -> False

metadataHasExecutorTarget :: T.Text -> Aeson.Value -> Bool
metadataHasExecutorTarget expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "executor" obj of
      Just (Aeson.Object executorObj) ->
        KeyMap.lookup "target" executorObj == Just (Aeson.String expected)
      _ -> False
  _ -> False

metadataHasInputContract :: T.Text -> T.Text -> Aeson.Value -> Bool
metadataHasInputContract portName contractName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "ports" obj of
      Just (Aeson.Object portsObj) ->
        case KeyMap.lookup "inputs" portsObj of
          Just (Aeson.Array inputs) ->
            any (inputHasContract portName contractName) inputs
          _ -> False
      _ -> False
  _ -> False
  where
    inputHasContract expectedPort expectedContract = \case
      Aeson.Object inputObj ->
        KeyMap.lookup "name" inputObj == Just (Aeson.String expectedPort)
          && case KeyMap.lookup "accepts" inputObj of
            Just (Aeson.Array contracts) -> Aeson.String expectedContract `elem` contracts
            _ -> False
      _ -> False

metadataHasOutputContract :: T.Text -> T.Text -> Aeson.Value -> Bool
metadataHasOutputContract portName contractName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "ports" obj of
      Just (Aeson.Object portsObj) ->
        case KeyMap.lookup "outputs" portsObj of
          Just (Aeson.Array outputs) ->
            any (outputHasContract portName contractName) outputs
          _ -> False
      _ -> False
  _ -> False
  where
    outputHasContract expectedPort expectedContract = \case
      Aeson.Object outputObj ->
        KeyMap.lookup "name" outputObj == Just (Aeson.String expectedPort)
          && KeyMap.lookup "contract" outputObj == Just (Aeson.String expectedContract)
      _ -> False

isRight :: Either err ok -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isParseFailure :: Either WireError ok -> Bool
isParseFailure = \case
  Left WireParseError {} -> True
  _ -> False

isCorePureScopeViolationOf :: T.Text -> Either WireError ok -> Bool
isCorePureScopeViolationOf capturedBinding = \case
  Left (WireInvalidPorts _ message) -> messageMatches message
  Left (WireParseError message) -> messageMatches message
  _ -> False
  where
    messageMatches message =
      ("cannot capture " <> capturedBinding) `T.isInfixOf` message

knownContractsEnv :: WireCompileEnv
knownContractsEnv =
  emptyWireCompileEnv
    { wireCompileEnvContractRegistry =
        Just $
          wireContractRegistryFromList
            [ jsonContract "PlannerOutput"
            , jsonContract "AnalysisFragment"
            , jsonContract "ResearchPlan"
            , jsonContract "PlanIssue"
            , jsonContract "DraftPlan"
            , jsonContract "ReportArtifactRef"
            ]
    }

strictExecutorEnv :: WireCompileEnv
strictExecutorEnv =
  emptyWireCompileEnv
    { wireCompileEnvExecutorRegistry =
        wireExecutorRegistryFromList
          [ wireExecutorProjectionFromPorts
              (WireExecutorId "review.projected")
              projectedExecutorPorts
              WireExecutorModel
          , pureWireExecutorProjection
          ]
    , wireCompileEnvProjectionMode = WireProjectionStrict
    }

quantumExecutorEnv :: WireCompileEnv
quantumExecutorEnv =
  emptyWireCompileEnv
    { wireCompileEnvExecutorRegistry =
        wireExecutorRegistryFromList
          [ quantumExecutorProjection "quantum.prepare_zero"
          , quantumExecutorProjection "quantum.h"
          , quantumExecutorProjection "quantum.rz"
          , quantumExecutorProjection "quantum.sx"
          , quantumExecutorProjection "quantum.x"
          , quantumExecutorProjection "quantum.cnot"
          , quantumExecutorProjection "quantum.cz"
          , quantumExecutorProjection "quantum.rzz"
          , quantumExecutorProjection "quantum.measure_z"
          , quantumExecutorProjection "quantum.ibm_runtime_config"
          ]
    , wireCompileEnvProjectionMode = WireProjectionStrict
    }

quantumExecutorProjection :: T.Text -> WireExecutorProjection
quantumExecutorProjection executorId =
  WireExecutorProjection
    { wireExecutorProjectionId = WireExecutorId executorId
    , wireExecutorProjectionPorts = WirePorts Map.empty Map.empty
    , wireExecutorProjectionVocabulary =
        Set.fromList ["Qubit", "Bit", "RotationAngle", "IBMQuantumConfig"]
    , wireExecutorProjectionEffect = WireExecutorHostEffect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

projectedExecutorPorts :: WirePorts
projectedExecutorPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.singleton
          "out"
          WireOutputPort {wireOutputPortContract = "PlannerOutput"}
    }

jsonContract :: T.Text -> WireContractSpec
jsonContract contractId =
  WireContractSpec
    { wireContractSpecId = contractId
    , wireContractSpecPayloadKind = WirePayloadJson
    , wireContractSpecDescription = contractId
    , wireContractSpecSchema = Nothing
    , wireContractSpecExamples = []
    }
