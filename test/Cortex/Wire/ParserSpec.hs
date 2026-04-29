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

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire.Parser
import Cortex.Wire.Syntax

parseOrFail :: Text -> WireFile
parseOrFail src = case parseWireFile "test" src of
  Left err -> error ("parse failed: " <> show (renderParseError err))
  Right ok -> ok

spec :: Spec
spec = describe "Cortex.Wire.Parser" $ do
  describe "guardrails" $ do
    it "rejects legacy colon node declarations" $
      parseWireFile "test" "node n : -> out: T = @llm.x ({});"
        `shouldSatisfy` isParseFailure

    it "rejects legacy list input aggregation syntax" $
      parseWireFile "test" "node sink\n  <- errors: [ExecutorError] ;\n  = @artifact.log (errors) ;"
        `shouldSatisfy` isParseFailure

    it "rejects brace-form pure output equations" $
      parseWireFile "test" "node score\n  -> score: Score = pure { 1 ; } ;"
        `shouldSatisfy` isParseFailure

    it "rejects authored @pure executor calls" $
      parseWireFile "test" "node score\n  -> score: Score = @pure ({}) ;"
        `shouldSatisfy` isParseFailure

    it "rejects unparenthesized mixed topology operators" $
      parseWireExpr "test" "a => b <> c"
        `shouldSatisfy` isParseFailure

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
            , "  -> accepted: AcceptedSet = pure (items) ;"
            ]
        )
        `shouldSatisfy` isParseFailure

  describe "top-level forms" $ do
    it "parses exported scalar bindings as ordinary module lets" $ do
      let WireFile forms _ = parseOrFail "export let threshold = 0.7 ;"
      forms
        `shouldBe` [ TopLet
                       LetExported
                       "threshold"
                       (LetRhsWire (ExprLit (LitNumber 0.7)))
                   ]

    it "parses top-level lambdas as delayed CorePure helper bindings" $ do
      let WireFile forms _ = parseOrFail "let acceptedItem = item: item.score >= 0.7 ;"
      case forms of
        [TopLet LetPrivate "acceptedItem" (LetRhsCorePure CorePureLambda {})] -> pure ()
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses configured executor bindings" $ do
      let WireFile forms _ =
            parseOrFail "let analyst = @llm.analyst { temperature = 0.2 ; } ;"
      case forms of
        [ TopLet
            LetPrivate
            "analyst"
            (LetRhsWire (ExprConfiguredExecutor (QName ("llm" :| ["analyst"])) (Record fields)))
          ] ->
            length fields `shouldBe` 1
        other -> expectationFailure ("unexpected forms: " <> show other)

  describe "node declarations" $ do
    it "parses pure output equations with a where-clause" $ do
      let WireFile forms _ =
            parseOrFail $
              T.unlines
                [ "node classify"
                , "  <- evidence: EvidenceSet ;"
                , "  -> accepted: AcceptedSet = pure (accepted) ;"
                , "  -> rejected: RejectedSet = pure (rejected) ;"
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
                , "  -> analysis: AnalysisRecord = @llm.analyze (evidence) ;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor
              Nothing
              (ExecutorCallInline (QName ("llm" :| ["analyze"])) (Record []) (CorePureIdent "evidence")) ->
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
                , "  = @llm.analyzeWithUsage (evidence) ;"
                ]
      case forms of
        [TopNode node] ->
          case nodeDeclBody node of
            NodeBodyExecutor Nothing (ExecutorCallInline (QName ("llm" :| ["analyzeWithUsage"])) _ _) ->
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
                [ "let analyst = @llm.analyst { temperature = 0.2 ; } ;"
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
                , "  = @llm.analyze (payload) ;"
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
                , "  -> out: T = @llm.x ({}) ;"
                , "node b"
                , "  <- input: T ;"
                , "  -> out: U = @llm.y (input) ;"
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
        , "  -> out: T = pure (" <> source <> ") ;"
        ]

isParseFailure :: Either ParseError a -> Bool
isParseFailure result = case result of
  Left _ -> True
  Right _ -> False
