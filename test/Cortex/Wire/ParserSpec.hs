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
    , "  <- label: T ;"
    , "  -> label: T = @review.pass (label) ;"
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

    it "parses the C build example" $
      parseIncludedWireFixture "examples/wire/c-build/c-build.wire"

    it "parses the quantum Bell-state example" $
      parseWireFixture "examples/wire/quantum-bell-state.wire"

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
      parseWireFile "test" "node n : -> out: T = @review.x ({});"
        `shouldSatisfy` isParseFailure

    it "rejects legacy list input aggregation syntax" $
      parseWireFile "test" "node sink\n  <- errors: [ExecutorError] ;\n  = @artifact.log (errors) ;"
        `shouldSatisfy` isParseFailure

    it "rejects removed pure output wrappers" $
      parseWireFile "test" "node score\n  -> score: Score = pure (1) ;"
        `shouldSatisfy` isParseFailureContaining "pure (...) output wrappers were removed"

    it "rejects authored @pure executor calls" $
      parseWireFile "test" "node score\n  -> score: Score = @pure ({}) ;"
        `shouldSatisfy` isParseFailure

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
            , "  <- evidence: EvidenceSet ;"
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
            , "  <- label: T ;"
            , "  -> label: T = @review.pass (label) ;"
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
            , "    -> out: T = @review.pass ({}) ;"
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
            , "  -> label: Sample = @review.sample ({}) ;"
            , "let worker_names = [\"alpha\", \"alpha\"];"
            , "let workers = makeEach(worker_names, sample);"
            , "workers"
            ]
        )
        `shouldSatisfy` isParseFailureContaining "duplicate generated label alpha"

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
                , "  -> label: Sample = @review.sample ({}) ;"
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

    it "expands bound make forms with a preceding static count binding" $ do
      let WireFile forms fileReturn =
            parseOrFail $
              T.unlines
                [ "kind sample(label: PortLabel) ="
                , "  -> label: Sample = @review.sample ({}) ;"
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
                , "  -> label: Sample = @review.sample ({}) ;"
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

    it "parses configured executor bindings" $ do
      let WireFile forms _ =
            parseOrFail "let analyst = @review.analyst { temperature = 0.2 ; } ;"
      case forms of
        [ TopLet
            LetPrivate
            "analyst"
            (LetRhsWire (ExprConfiguredExecutor (QName ("review" :| ["analyst"])) (Record fields)))
          ] ->
            length fields `shouldBe` 1
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "expands kind applications into ordinary node declarations" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "let h_gate = @quantum.h {} ;"
                , "kind one_qubit_gate(label: PortLabel, gate: ConfiguredExecutor) ="
                , "  <- label: Qubit ;"
                , "  -> label: Qubit ;"
                , "  = gate (label) ;"
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
            NodeBodyExecutor Nothing (ExecutorCallConfigured "h_gate" (CorePureIdent "screen")) ->
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
            parseOrFail "let analyst = @review.analyst { inherit temperature; } ;"
      case forms of
        [ TopLet
            LetPrivate
            "analyst"
            (LetRhsWire (ExprConfiguredExecutor _ (Record fields)))
          ] ->
            fields
              `shouldBe` [ Field
                             ("temperature" :| [])
                             (ExprIdent (QName ("temperature" :| [])))
                         ]
        other -> expectationFailure ("unexpected forms: " <> show other)

  describe "node declarations" $ do
    it "parses pure output equations with a where-clause" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node classify"
                , "  <- evidence: EvidenceSet ;"
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
              length (nodePureBodyOutputs pureBody) `shouldBe` 2
            other -> expectationFailure ("expected pure body, got: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses single-output external shorthand" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node analyze"
                , "  <- evidence: EvidenceSet ;"
                , "  -> analysis: AnalysisRecord = @review.analyze (evidence) ;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor
              Nothing
              (ExecutorCallInline (QName ("review" :| ["analyze"])) (Record []) (CorePureIdent "evidence")) ->
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
                , "  <- evidence: EvidenceSet ;"
                , "  -> analysis: AnalysisRecord ;"
                , "  -> usage: UsageMetadata ;"
                , "  = @review.analyzeWithUsage (evidence) ;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor Nothing (ExecutorCallInline (QName ("review" :| ["analyzeWithUsage"])) _ _) ->
              length (nodeDeclPortSig node) `shouldBe` 3
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses zero-output executor bodies" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node logEvent"
                , "  <- event: Event ;"
                , "  = @artifact.log (event) ;"
                ]
      case forms of
        [TopNode node] ->
          nodeDeclPortSig node
            `shouldBe` [PortInputDecl (Label "event") (ContractId "Event")]
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses configured executor applications" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "let analyst = @review.analyst { temperature = 0.2 ; } ;"
                , "node analyze"
                , "  <- evidence: EvidenceSet ;"
                , "  -> analysis: AnalysisRecord ;"
                , "  = analyst (evidence) ;"
                ]
      case forms of
        [_, TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor Nothing (ExecutorCallConfigured "analyst" (CorePureIdent "evidence")) -> pure ()
            other -> expectationFailure ("unexpected body: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses where-clauses on executor bodies" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node analyze"
                , "  <- evidence: EvidenceSet ;"
                , "  -> analysis: AnalysisRecord ;"
                , "  = @review.analyze (payload) ;"
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

  describe "file-return expressions" $ do
    it "parses a file with a parenthesized mixed topology expression" $ do
      let WireFile forms ret =
            parseOrFail $
              T.unlines
                [ "node a"
                , "  -> out: T = @review.x ({}) ;"
                , "node b"
                , "  <- input: T ;"
                , "  -> out: U = @review.y (input) ;"
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
        NodeBodyPure pureBody ->
          pureOutputEquationExpr (NE.head pureBody.nodePureBodyOutputs)
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
