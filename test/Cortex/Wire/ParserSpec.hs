{- |
Module      : Cortex.Wire.ParserSpec
Description : Tests for Cortex.Wire.Parser.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.ParserSpec (spec) where

import Data.Either (isRight)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Wire.Include (expandWireSourceIncludes)
import Cortex.Wire.Parser
import Cortex.Wire.Syntax

parseOrFail :: Text -> WireFile
parseOrFail src = case parseWireFile "test" src of
  Left err -> error ("parse failed: " <> show (renderParseError err))
  Right ok -> ok

parseWireFixture :: FilePath -> Expectation
parseWireFixture path = do
  source <- TIO.readFile path
  parseWireFile path source `shouldSatisfy` isRight

parseIncludedWireFixture :: FilePath -> Expectation
parseIncludedWireFixture path = do
  source <- TIO.readFile path
  expanded <- requireRightIO (expandWireSourceIncludes path source)
  parseWireFile path expanded `shouldSatisfy` isRight

requireRightIO :: Show err => IO (Either err a) -> IO a
requireRightIO action =
  action >>= \case
    Left err -> expectationFailure ("expected Right, got Left " <> show err) >> error "unreachable"
    Right value -> pure value

topFormName :: TopForm -> Maybe Text
topFormName topForm =
  case topForm of
    TopNode nodeDecl ->
      Just nodeDecl.nodeDeclName
    TopLet _ name _ ->
      Just name
    TopContract contractDeclValue ->
      Just contractDeclValue.contractDeclId.unContractId
    TopUse {} ->
      Nothing
    TopImport {} ->
      Nothing

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

graphFormSourceText :: Text
graphFormSourceText =
  T.unlines
    [ "kind pass(label: PortLabel) ="
    , "  <- label: T "
    , "  -> label: T = @review.pass label ;"
    , "form two_passes() = {"
    , "  node first = pass(value);"
    , "  node second = pass(value);"
    , "  first => second;"
    , "};"
    , "let pipeline = two_passes();"
    , "pipeline"
    ]

spec :: Spec
spec = describe "Cortex.Wire.Parser" $ do
  describe "examples" $ do
    it "parses the interactive priority planner example" $
      parseWireFixture "examples/wire/interactive-priority-planner.wire"

    it "parses the mini build-system example" $
      parseWireFixture "examples/wire/mini-build-system.wire"

    it "runtime-bounded iteration Wire example: parses the paginated ingest kernel" $
      parseWireFixture "examples/wire/runtime-bounded-paginated-ingest/page-kernel.wire"

    it "parses the pure stdlib report example" $
      parseWireFixture "examples/wire/pure-stdlib-report.wire"

    it "parses the C build example" $
      parseIncludedWireFixture "examples/wire/c-build/c-build.wire"

    it "parses the quantum Bell-state example" $
      parseWireFixture "examples/wire/quantum-bell-state.wire"

  describe "pure sum bodies" $ do
    it "parses constructors only after one declared exclusive output boundary" $ do
      let WireFile forms _ =
            parseOrFail
              "node classify <- score: Score -> accepted: Decision | rejected: RejectReason = if score >= 0 then accepted score else rejected score;"
      case forms of
        [ TopNode
            NodeDecl
              { nodeDeclBody =
                NodeBodyPure
                  ( NodePureBody
                      Nothing
                      (NodePureSum variants (CorePureIf {}))
                    )
              }
          ] -> fmap (.svLabel) variants `shouldBe` Label "accepted" :| [Label "rejected"]
        other -> expectationFailure ("unexpected pure sum parse: " <> show other)

    it "parses the IBM REST quantum Bell-state example" $
      parseWireFixture "examples/wire/quantum-bell-state-ibm-rest.wire"

    it "parses the quantum IPEA round example" $
      parseWireFixture "examples/wire/quantum-ipea-round.wire"

    it "parses the quantum eraser round example" $
      parseWireFixture "examples/wire/quantum-eraser-round.wire"

    it "parses the full quantum eraser experiment scaffold" $
      parseWireFixture "examples/wire/quantum-eraser-experiment.wire"

    it "parses the quantum eraser sweep circuit examples" $
      mapM_ parseWireFixture quantumEraserSweepFixtures

  describe "guardrails" $ do
    it "rejects legacy colon node declarations" $
      parseWireFile "test" "node n : -> out: T = @review.x ;"
        `shouldSatisfy` isParseFailure

    it "rejects legacy list input aggregation syntax" $
      parseWireFile "test" "node sink\n  <- errors: [ExecutorError] \n  = @artifact.log errors ;"
        `shouldSatisfy` isParseFailure

    it "rejects removed pure output wrappers" $
      parseWireFile "test" "node score\n  -> score: Score = pure (1) ;"
        `shouldSatisfy` isParseFailureContaining "pure (...) output wrappers were removed"

    it "rejects authored @pure executor calls" $
      parseWireFile "test" "node score\n  -> score: Score = @pure ;"
        `shouldSatisfy` isParseFailure

    it "rejects parenthesized executor calls with a targeted diagnostic" $
      parseWireFile "test" "node n -> out: T = @review.x (value);"
        `shouldSatisfy` isParseFailureContaining "parenthesized executor calls were removed"

    it "rejects multiple executor arguments" $
      parseWireFile "test" "node n -> out: T = @review.x first, second;"
        `shouldSatisfy` isParseFailure

    it "rejects semicolon-delimited input port clauses with a targeted diagnostic" $
      parseWireFile "test" "node n <- value: T; = @review.x value;"
        `shouldSatisfy` isParseFailureContaining "semicolon-delimited port declarations were removed"

    it "rejects semicolon-delimited multiline input ports with a targeted diagnostic" $
      parseWireFile "test" "node n\n  <- value: T;\n  -> out: U = @review.x value;"
        `shouldSatisfy` isParseFailureContaining "semicolon-delimited port declarations were removed"

    it "rejects semicolon-delimited output port clauses with a targeted diagnostic" $
      parseWireFile "test" "node n\n  <- value: T\n  -> out: U;\n  = @review.x value;"
        `shouldSatisfy` isParseFailureContaining "semicolon-delimited port declarations were removed"

    it "rejects the obsolete ConfiguredExecutor parameter class" $
      parseWireFile "test" "kind k(exec: ConfiguredExecutor) = -> out: T = @exec;"
        `shouldSatisfy` isParseFailureContaining "ConfiguredExecutor was removed; use Executor"

    it "rejects wildcard registry namespace use imports" $
      parseWireFile "test" "use std.io.*;"
        `shouldSatisfy` isParseFailure

    it "parses mixed topology operators with overlay binding tighter than connect" $
      parseWireExpr "test" "a => b <> c"
        `shouldSatisfy` isRight

    it "parses star adapters at connect precedence" $
      case parseWireExpr "test" "(a <> b) * sink" of
        Right parsed ->
          parsed
            `shouldBe` ExprStar
              ( ExprOverlay
                  (ExprIdent (QName ("a" :| [])))
                  (ExprIdent (QName ("b" :| [])))
              )
              (ExprIdent (QName ("sink" :| [])))
        Left err -> expectationFailure ("parse failed: " <> T.unpack (renderParseError err))

    it "rejects comma overlay tuple shorthand" $
      parseWireExpr "test" "(a, b)"
        `shouldSatisfy` isParseFailure

    it "rejects node-local let blocks before node bodies" $
      parseWireFile
        "test"
        ( T.unlines
            [ "node classify"
            , "  <- evidence: EvidenceSet "
            , "  let"
            , "    items = evidence.items ;"
            , "  in"
            , "  -> accepted: AcceptedSet = items ;"
            ]
        )
        `shouldSatisfy` isParseFailure

    it "rejects bare kind applications outside node-instantiation position" $
      parseWireFile
        "test"
        ( T.unlines
            [ "kind pass(label: PortLabel) ="
            , "  <- label: T "
            , "  -> label: T = @review.pass label ;"
            , "pass(value);"
            ]
        )
        `shouldSatisfy` isParseFailure

    it "rejects bare form applications outside bound let position" $
      parseWireFile
        "test"
        ( T.unlines
            [ "form pass() = {"
            , "  node n"
            , "    -> out: T = @review.pass ;"
            , "  n;"
            , "};"
            , "pass();"
            ]
        )
        `shouldSatisfy` isParseFailure

    it "rejects makeEach items with duplicate generated labels" $
      parseWireFile
        "test"
        ( T.unlines
            [ "kind sample(label: PortLabel) ="
            , "  -> label: Sample = @review.sample ;"
            , "let worker_names = [\"alpha\", \"alpha\"];"
            , "let workers = makeEach(worker_names, sample);"
            , "workers"
            ]
        )
        `shouldSatisfy` isParseFailureContaining "duplicate generated label alpha"

    it "rejects leading zeros in indexed syntax" $ do
      parseWireExpr "test" "workers[01]"
        `shouldSatisfy` isParseFailureContaining "must not contain leading zeros"
      parseWireFile
        "test"
        ( T.unlines
            [ "contract SampleBatch {"
            , "  samples: [Sample; 03];"
            , "};"
            ]
        )
        `shouldSatisfy` isParseFailureContaining "must not contain leading zeros"

  describe "top-level forms" $ do
    it "parses exported scalar bindings as ordinary module lets" $ do
      let WireFile forms _ = parseOrFail "export let threshold = 0.7 ;"
      forms
        `shouldBe` [ TopLet
                       LetExported
                       "threshold"
                       (LetRhsWire (ExprLit (LitNumber 0.7)))
                   ]

    it "expands bound graph forms into scoped ordinary graph declarations" $ do
      let WireFile forms fileReturn = parseOrFail graphFormSourceText
      fmap topFormName forms
        `shouldBe` [ Just "pipeline/first"
                   , Just "pipeline/second"
                   , Just "pipeline"
                   ]
      fileReturn `shouldBe` Just (ExprIdent (QName ("pipeline" :| [])))

    it "expands bound make forms into generated nodes and a graph binding" $ do
      let WireFile forms fileReturn =
            parseOrFail $
              T.unlines
                [ "kind sample(label: PortLabel) ="
                , "  -> label: Sample = @review.sample ;"
                , "let workers = make(2, sample);"
                , "workers"
                ]
      fmap topFormName forms
        `shouldBe` [Just "workers_0", Just "workers_1", Just "workers"]
      fileReturn `shouldBe` Just (ExprIdent (QName ("workers" :| [])))
      case forms of
        [TopNode first, TopNode second, TopLet LetPrivate "workers" (LetRhsWire graphExpr)] -> do
          nodeDeclName first `shouldBe` "workers_0"
          nodeDeclName second `shouldBe` "workers_1"
          graphExpr
            `shouldBe` ExprOverlay
              (ExprIdent (QName ("workers_0" :| [])))
              (ExprIdent (QName ("workers_1" :| [])))
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "expands indexed make bindings and resolves static family projections" $ do
      let WireFile forms fileReturn =
            parseOrFail $
              T.unlines
                [ "kind sample(label: PortLabel) ="
                , "  -> label: Sample = @review.sample ;"
                , "let workers[] = make(2, sample);"
                , "workers[1]"
                ]
      fmap topFormName forms
        `shouldBe` [Just "workers_0", Just "workers_1", Just "workers"]
      fileReturn `shouldBe` Just (ExprIdent (QName ("workers_1" :| [])))

    it "rejects out-of-range indexed make projections" $
      parseWireFile
        "test"
        ( T.unlines
            [ "kind sample(label: PortLabel) ="
            , "  -> label: Sample = @review.sample ;"
            , "let workers[] = make(2, sample);"
            , "workers[2]"
            ]
        )
        `shouldSatisfy` isParseFailureContaining "out of range for family of size 2"

    it "keeps ordinary CorePure index syntax in value lets" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "let item = items[0];"
                ]
      case forms of
        [TopLet LetPrivate "item" (LetRhsCorePure coreExpr)] ->
          coreExpr
            `shouldBe` CorePureIndex
              (CorePureIdent "items")
              (CorePureLit (CorePureNumber 0))
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "keeps spaced CorePure list calls in value lets" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "let item = f [0];"
                ]
      case forms of
        [TopLet LetPrivate "item" (LetRhsCorePure coreExpr)] ->
          coreExpr
            `shouldBe` CorePureCall
              (CorePureIdent "f")
              [CorePureList [CorePureLit (CorePureNumber 0)]]
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "keeps form-local CorePure index lets as CorePure" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "form select_first(items: Value) = {"
                , "  let item = items[0];"
                , "  item;"
                , "};"
                , "let selected = select_first([10]);"
                ]
      case forms of
        [ TopLet LetPrivate "selected/item" (LetRhsCorePure coreExpr)
          , TopLet LetPrivate "selected" (LetRhsWire (ExprIdent (QName ("selected/item" :| []))))
          ] ->
            coreExpr
              `shouldBe` CorePureIndex
                (CorePureList [CorePureLit (CorePureNumber 10)])
                (CorePureLit (CorePureNumber 0))
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "expands bound make forms with a preceding static count binding" $ do
      let WireFile forms fileReturn =
            parseOrFail $
              T.unlines
                [ "kind sample(label: PortLabel) ="
                , "  -> label: Sample = @review.sample ;"
                , "let count = 2;"
                , "let workers = make(count, sample);"
                , "workers"
                ]
      fmap topFormName forms
        `shouldBe` [Just "count", Just "workers_0", Just "workers_1", Just "workers"]
      fileReturn `shouldBe` Just (ExprIdent (QName ("workers" :| [])))

    it "expands form-local make forms with a preceding static count binding" $ do
      let WireFile forms fileReturn =
            parseOrFail $
              T.unlines
                [ "kind sample(label: PortLabel) ="
                , "  -> label: Sample = @review.sample ;"
                , "form batch_form() = {"
                , "  let count = 2;"
                , "  let workers = make(count, sample);"
                , "  workers;"
                , "};"
                , "let batch = batch_form();"
                , "batch"
                ]
      fmap topFormName forms
        `shouldBe` [ Just "batch/count"
                   , Just "batch/workers_0"
                   , Just "batch/workers_1"
                   , Just "batch/workers"
                   , Just "batch"
                   ]
      fileReturn `shouldBe` Just (ExprIdent (QName ("batch" :| [])))

    it "expands makeEach forms from static item records" $ do
      let WireFile forms fileReturn =
            parseOrFail $
              T.unlines
                [ "kind sample(label: PortLabel, item: Value) ="
                , "  -> label: Sample = item ;"
                , "let source_items = ["
                , "  { label = \"alpha\"; path = \"src/alpha.c\"; },"
                , "  { label = \"beta\"; path = \"src/beta.c\"; },"
                , "];"
                , "let workers = makeEach(source_items, sample);"
                , "workers"
                ]
      fmap topFormName forms
        `shouldBe` [ Just "source_items"
                   , Just "workers_alpha"
                   , Just "workers_beta"
                   , Just "workers"
                   ]
      fileReturn `shouldBe` Just (ExprIdent (QName ("workers" :| [])))

    it "parses top-level lambdas as delayed CorePure helper bindings" $ do
      let WireFile forms _ = parseOrFail "let acceptedItem = item: item.score >= 0.7 ;"
      case forms of
        [TopLet LetPrivate "acceptedItem" (LetRhsCorePure CorePureLambda {})] -> pure ()
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses executor authority bindings" $ do
      let WireFile forms _ =
            parseOrFail "let analyst = @review.analyst;"
      case forms of
        [ TopLet
            LetPrivate
            "analyst"
            (LetRhsWire (ExprExecutor (QName ("review" :| ["analyst"]))))
          ] -> pure ()
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses bounded indexed product contracts in port positions" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node sink"
                , "  <- samples: [Sample; 3]"
                , "  -> done: Done = @review.sink samples;"
                ]
      case forms of
        [TopNode node] ->
          nodeDeclPortSig node
            `shouldBe` [ PortInputDecl (Label "samples") (ContractId "[Sample;3]")
                       , PortOutputDecl (Label "done") (ContractId "Done")
                       ]
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "expands kind applications into ordinary node declarations" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "let h_gate = @quantum.h;"
                , "kind one_qubit_gate(label: PortLabel, gate: Executor) ="
                , "  <- label: Qubit"
                , "  -> label: Qubit"
                , "  = @gate label;"
                , "node screen_h = one_qubit_gate(screen, h_gate);"
                , "screen_h"
                ]
      case forms of
        [_, TopNode node] -> do
          nodeDeclName node `shouldBe` "screen_h"
          nodeDeclPortSig node
            `shouldBe` [ PortInputDecl (Label "screen") (ContractId "Qubit")
                       , PortOutputDecl (Label "screen") (ContractId "Qubit")
                       ]
          case nodeDeclBody node of
            NodeBodyExecutor Nothing (ExecutorCallBound "h_gate" (Just (CorePureIdent "screen"))) ->
              pure ()
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses registry namespace use imports" $ do
      let WireFile forms _ =
            parseOrFail "use std.io.{@command as @shell, CommandSpec as Spec};"
      forms
        `shouldBe` [ TopUse
                       UseSpec
                         { useSpecNamespace = QName ("std" :| ["io"])
                         , useSpecItems =
                             UseExecutor "command" (Just "shell")
                               :| [UseContract "CommandSpec" (Just "Spec")]
                         }
                   ]

    it "desugars ordinary record inherit fields" $ do
      let WireFile forms _ =
            parseOrFail "let args = { inherit temperature; };"
      case forms of
        [ TopLet
            LetPrivate
            "args"
            (LetRhsWire (ExprRecord (Record fields)))
          ] ->
            fields
              `shouldBe` [ Field
                             ("temperature" :| [])
                             (ExprIdent (QName ("temperature" :| [])))
                         ]
        other -> expectationFailure ("unexpected forms: " <> show other)

  describe "node declarations" $ do
    it "parses static node metadata and a zero-argument executor call" $ do
      let WireFile forms _ =
            parseOrFail "node fetch with { timeout = 30; } -> result: Result = @review.fetch;"
      case forms of
        [TopNode node] -> do
          node.nodeDeclMetadata
            `shouldBe` Just
              (Record [Field ("timeout" :| []) (ExprLit (LitNumber 30))])
          node.nodeDeclBody
            `shouldBe` NodeBodyExecutor
              Nothing
              (ExecutorCallInline (QName ("review" :| ["fetch"])) Nothing)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses pure output equations with a where-clause" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node classify"
                , "  <- evidence: EvidenceSet"
                , "  -> accepted: AcceptedSet = evidence.items |> filter (x: x.score >= 0.7) ;"
                , "  -> rejected: RejectedSet = evidence.items |> filter (x: x.score < 0.7) ;"
                , "  where let"
                , "    items = evidence.items ;"
                , "    accepted = items |> filter (x: x.score >= 0.7) ;"
                , "    rejected = items |> filter (x: x.score < 0.7) ;"
                , "  in"
                , "  { accepted = accepted ; rejected = rejected ; } ;"
                ]
      case forms of
        [TopNode node] -> do
          nodeDeclPortSig node
            `shouldBe` [ PortInputDecl (Label "evidence") (ContractId "EvidenceSet")
                       , PortOutputDecl (Label "accepted") (ContractId "AcceptedSet")
                       , PortOutputDecl (Label "rejected") (ContractId "RejectedSet")
                       ]
          case nodeDeclBody node of
            NodeBodyPure pureBody -> do
              nodePureBodyWhere pureBody `shouldSatisfy` isJust
              case pureBody.nodePureBodyResult of
                NodePureProduct outputs -> length outputs `shouldBe` 2
                other -> expectationFailure ("expected product outputs, got: " <> show other)
            other -> expectationFailure ("expected pure body, got: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses single-output external shorthand" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node analyze"
                , "  <- evidence: EvidenceSet"
                , "  -> analysis: AnalysisRecord = @review.analyze evidence;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor
              Nothing
              (ExecutorCallInline (QName ("review" :| ["analyze"])) (Just (CorePureIdent "evidence"))) ->
                nodeDeclPortSig node
                  `shouldBe` [ PortInputDecl (Label "evidence") (ContractId "EvidenceSet")
                             , PortOutputDecl (Label "analysis") (ContractId "AnalysisRecord")
                             ]
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses multi-output executor bodies" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node analyze"
                , "  <- evidence: EvidenceSet"
                , "  -> analysis: AnalysisRecord"
                , "  -> usage: UsageMetadata"
                , "  = @review.analyzeWithUsage evidence;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor Nothing (ExecutorCallInline (QName ("review" :| ["analyzeWithUsage"])) _) ->
              length (nodeDeclPortSig node) `shouldBe` 3
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses zero-output executor bodies" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node logEvent"
                , "  <- event: Event"
                , "  = @artifact.log event;"
                ]
      case forms of
        [TopNode node] ->
          nodeDeclPortSig node
            `shouldBe` [PortInputDecl (Label "event") (ContractId "Event")]
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses bound executor applications" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "let analyst = @review.analyst;"
                , "node analyze"
                , "  <- evidence: EvidenceSet"
                , "  -> analysis: AnalysisRecord"
                , "  = @analyst evidence;"
                ]
      case forms of
        [_, TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor
              Nothing
              (ExecutorCallInline (QName ("analyst" :| [])) (Just (CorePureIdent "evidence"))) -> pure ()
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses where-clauses on executor bodies" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node analyze"
                , "  <- evidence: EvidenceSet"
                , "  -> analysis: AnalysisRecord"
                , "  = @review.analyze payload;"
                , "  where { payload = { items = evidence.items ; } ; } ;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor (Just (CorePureRecord _)) _ -> pure ()
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

  describe "CorePure expressions" $ do
    it "desugars pipes into function application" $
      parseCorePureNodeOutput "xs |> filter pred |> map f"
        `shouldBe` CorePureCall
          (CorePureCall (CorePureIdent "map") [CorePureIdent "f"])
          [ CorePureCall
              (CorePureCall (CorePureIdent "filter") [CorePureIdent "pred"])
              [CorePureIdent "xs"]
          ]

    it "parses CorePure record merge" $
      parseCorePureNodeOutput "{ a = 1 ; } // { b = 2 ; }"
        `shouldBe` CorePureBinary
          CorePureMerge
          (CorePureRecord [CorePureField ("a" :| []) (CorePureLit (CorePureNumber 1))])
          (CorePureRecord [CorePureField ("b" :| []) (CorePureLit (CorePureNumber 2))])

    it "desugars CorePure record inherit fields" $
      parseCorePureNodeOutput "{ inherit accepted rejected; }"
        `shouldBe` CorePureRecord
          [ CorePureField ("accepted" :| []) (CorePureIdent "accepted")
          , CorePureField ("rejected" :| []) (CorePureIdent "rejected")
          ]

    it "desugars CorePure source inheritance" $
      parseCorePureNodeOutput "{ inherit (x) payload cfg; }"
        `shouldBe` CorePureRecord
          [ CorePureField ("payload" :| []) (CorePureFieldAccess (CorePureIdent "x") "payload")
          , CorePureField ("cfg" :| []) (CorePureFieldAccess (CorePureIdent "x") "cfg")
          ]

    it "parses if-then-else" $
      parseCorePureNodeOutput "if accepted then \"yes\" else \"no\""
        `shouldBe` CorePureIf
          (CorePureIdent "accepted")
          (CorePureLit (CorePureString "yes"))
          (CorePureLit (CorePureString "no"))

    it "desugars interpolation to concat and toString" $
      parseCorePureNodeOutput "\"Score: ${score}\""
        `shouldBe` CorePureCall
          (CorePureIdent "concat")
          [ CorePureList
              [ CorePureLit (CorePureString "Score: ")
              , CorePureCall (CorePureIdent "toString") [CorePureIdent "score"]
              ]
          ]

    it "parses separated bracket lists as function arguments" $
      parseCorePureNodeOutput "concat [toString score]"
        `shouldBe` CorePureCall
          (CorePureIdent "concat")
          [CorePureList [CorePureCall (CorePureIdent "toString") [CorePureIdent "score"]]]

    it "treats block comments as bracket argument separators" $
      parseCorePureNodeOutput "concat/* explain */[toString score]"
        `shouldBe` CorePureCall
          (CorePureIdent "concat")
          [CorePureList [CorePureCall (CorePureIdent "toString") [CorePureIdent "score"]]]

    it "parses immediate brackets as index access" $
      parseCorePureNodeOutput "items[0]"
        `shouldBe` CorePureIndex
          (CorePureIdent "items")
          (CorePureLit (CorePureNumber 0))

  describe "file-return expressions" $ do
    it "parses a file with a parenthesized mixed topology expression" $ do
      let WireFile forms ret =
            parseOrFail $
              T.unlines
                [ "node a"
                , "  -> out: T = @review.x ;"
                , "node b"
                , "  <- input: T "
                , "  -> out: U = @review.y input ;"
                , "(a) => b"
                ]
      length forms `shouldBe` 2
      case ret of
        Just (ExprConnect _ _) -> pure ()
        other -> expectationFailure ("unexpected return: " <> show other)

parseCorePureNodeOutput :: Text -> CorePureExpr
parseCorePureNodeOutput source =
  case parseWireFile "test" program of
    Right (WireFile [TopNode node] _) ->
      case nodeDeclBody node of
        NodeBodyPure (NodePureBody _ (NodePureProduct outputs)) ->
          pureOutputEquationExpr (NE.head outputs)
        other -> error ("unexpected node body: " <> show other)
    other -> error ("unexpected parse result: " <> show other)
  where
    program =
      T.unlines
        [ "node value"
        , "  -> out: T = " <> source <> " ;"
        ]

isParseFailure :: Either ParseError a -> Bool
isParseFailure result = case result of
  Left _ -> True
  Right _ -> False

isParseFailureContaining :: Text -> Either ParseError a -> Bool
isParseFailureContaining expected result = case result of
  Left err -> expected `T.isInfixOf` renderParseError err
  Right _ -> False
