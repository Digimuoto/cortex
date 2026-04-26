{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.V1.ParserSpec (spec) where

import Cortex.Wire.V1
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Test.Hspec

-- | Parse or fail with a helpful message (for use inside @shouldSatisfy@).
parseOrFail :: Text -> WireFile
parseOrFail src = case parseWireFile "test" src of
  Left err -> error ("parse failed: " <> show (renderParseError err))
  Right ok -> ok

spec :: Spec
spec = describe "Cortex.Wire.V1.Parser" $ do
  describe "spec guardrails" $ do
    it "rejects zero-port nodes" $
      parseWireFile "test" "node n : = @llm.x {};"
        `shouldSatisfy` isParseFailure

    it "rejects single-element tuples with a trailing comma" $
      parseWireExpr "test" "(a,)"
        `shouldSatisfy` isParseFailure

    it "rejects raw newlines inside single-line strings" $
      parseWireExpr "test" "\"a\nb\""
        `shouldSatisfy` isParseFailure

  describe "top-level forms" $ do
    it "parses a contract assertion" $ do
      let WireFile forms _ = parseOrFail "contract EvidenceBundle;"
      forms `shouldBe` [TopContract (ContractId "EvidenceBundle")]

    it "parses a let binding with a string literal" $ do
      let WireFile forms _ = parseOrFail "let greeting = \"hello\";"
      forms
        `shouldBe` [ TopLet "greeting" (ExprLit (LitString "hello"))
                   ]

    it "parses a named import" $ do
      let WireFile forms _ =
            parseOrFail "import shared from \"./lib.wire\";"
      forms
        `shouldBe` [TopImport (ImportNamed "shared" "./lib.wire")]

    it "parses an explicit import list" $ do
      let WireFile forms _ =
            parseOrFail "import { gatherer, analyst } from \"./gatherers.wire\";"
      forms
        `shouldBe` [ TopImport
                       ( ImportExplicit
                           ["gatherer", "analyst"]
                           "./gatherers.wire"
                       )
                   ]

  describe "node declarations" $ do
    it "parses a minimal sink node" $ do
      let WireFile forms _ =
            parseOrFail
              "node sink : <- [ExecutorError] = @artifact.log {};"
      forms
        `shouldBe` [ TopNode
                       ( NodeDecl
                           "sink"
                           [ PortInputDecl
                               NoLabel
                               (ContractId "ExecutorError")
                               PortList
                           ]
                           ( ExprApply
                               (QName ("artifact" :| ["log"]))
                               (Record [])
                           )
                       )
                   ]

    it "parses a sum-typed output with ExecutorError variant" $ do
      let WireFile forms _ =
            parseOrFail
              "node planner : -> PlannerOutput | ExecutorError = @llm.planner {};"
      case forms of
        [TopNode node] -> do
          nodeDeclName node `shouldBe` "planner"
          case nodeDeclPortSig node of
            [PortOutputSumDecl variants] ->
              let vlist = foldr (:) [] variants
               in fmap svContract vlist
                    `shouldBe` [ ContractId "PlannerOutput",
                                 ContractId "ExecutorError"
                               ]
            other -> expectationFailure ("unexpected port sig: " <> show other)
        other -> expectationFailure ("unexpected forms: " <> show other)

    it "parses labeled ports with contract disambiguation" $ do
      let WireFile forms _ =
            parseOrFail
              "node router : <- Report -> primary: Claim -> fallback: Claim = @llm.router {};"
      case forms of
        [TopNode node] ->
          nodeDeclPortSig node
            `shouldBe` [ PortInputDecl NoLabel (ContractId "Report") PortSingular,
                         PortOutputDecl (Label "primary") (ContractId "Claim"),
                         PortOutputDecl (Label "fallback") (ContractId "Claim")
                       ]
        other -> expectationFailure ("unexpected forms: " <> show other)

  describe "expressions" $ do
    it "parses a linear => chain" $ do
      case parseWireExpr "test" "a => b => c" of
        Right (ExprConnect (ExprConnect (ExprIdent _) (ExprIdent _)) (ExprIdent _)) ->
          pure ()
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses <> and => with correct precedence" $ do
      case parseWireExpr "test" "a => b <> c => d" of
        Right (ExprOverlay (ExprConnect _ _) (ExprConnect _ _)) -> pure ()
        other ->
          expectationFailure
            ("expected (a=>b) <> (c=>d), got: " <> show other)

    it "parses postfix select with named arms" $ do
      case parseWireExpr "test" "validate_plan select(ResearchPlan: (), PlanIssue: repair_plan)" of
        Right (ExprSelect (ExprIdent _) arms) -> do
          fmap selectArmKey (foldr (:) [] arms)
            `shouldBe` ["ResearchPlan", "PlanIssue"]
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses select tighter than =>" $ do
      case parseWireExpr
        "test"
        "plan => validate_plan select(ResearchPlan: (), PlanIssue: repair_plan) => publish_report" of
        Right
          ( ExprConnect
              (ExprConnect (ExprIdent _) (ExprSelect (ExprIdent _) _))
              (ExprIdent _)
            ) -> pure ()
        other ->
          expectationFailure
            ("expected (plan => (validate_plan select(...))) => publish_report, got: " <> show other)

    it "parses tuples inside select arms when parenthesized" $ do
      case parseWireExpr
        "test"
        "router select(Left: (a, b), Right: c)" of
        Right (ExprSelect _ arms) ->
          case foldr (:) [] arms of
            [SelectArm "Left" (ExprTuple items), SelectArm "Right" (ExprIdent _)] ->
              length items `shouldBe` 2
            other -> expectationFailure ("unexpected arms: " <> show other)
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses // and ++ at the same precedence level" $ do
      case parseWireExpr "test" "base // { k = \"v\"; } // { j = \"w\"; }" of
        Right (ExprMerge (ExprMerge _ _) _) -> pure ()
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses ''multiline'' strings verbatim" $ do
      case parseWireExpr "test" "''hello\nworld''" of
        Right (ExprLit (LitMultilineString s)) -> s `shouldBe` "hello\nworld"
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses list concatenation" $ do
      case parseWireExpr "test" "[a, b] ++ [c]" of
        Right (ExprConcat (ExprList _) (ExprList _)) -> pure ()
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses a tuple at graph position" $ do
      case parseWireExpr "test" "(a, b, c)" of
        Right (ExprTuple items) -> length items `shouldBe` 3
        other -> expectationFailure ("unexpected: " <> show other)

    it "parses @executor { field = val; }" $ do
      case parseWireExpr
        "test"
        "@llm.analyst { maxOutputTokens = 16384; memory = topological { preset = \"analyst\"; }; }" of
        Right (ExprApply (QName ("llm" :| ["analyst"])) (Record fields)) ->
          length fields `shouldBe` 2
        other -> expectationFailure ("unexpected: " <> show other)

    it "rejects comma-separated executor config fields" $
      parseWireExpr
        "test"
        "@llm.analyst { prompt = \"Find current evidence.\", tools = [webSearch], }"
        `shouldSatisfy` isParseFailure

    it "rejects unterminated executor config fields" $
      parseWireExpr
        "test"
        "@llm.analyst {\n  prompt = \"Find current evidence.\"\n  ; tools = [webSearch]\n}"
        `shouldSatisfy` isParseFailure

    it "parses a bare @llm executor reference as a single-segment qname" $ do
      case parseWireExpr "test" "@llm {}" of
        Right (ExprApply (QName ("llm" :| [])) (Record [])) ->
          pure ()
        other -> expectationFailure ("unexpected: " <> show other)

  describe "file-return expressions" $ do
    it "parses a file with a trailing expression and no ;" $ do
      let src =
            "node a : -> T = @llm.x {};\n\
            \node b : <- T -> U = @llm.y {};\n\
            \a => b"
      let WireFile forms ret = parseOrFail src
      length forms `shouldBe` 2
      case ret of
        Just (ExprConnect _ _) -> pure ()
        other ->
          expectationFailure
            ("expected a => b file-return, got: " <> show other)

    it "parses a declaration-only file (no return)" $ do
      let src =
            "contract X;\n\
            \let shared = \"prompt\";\n"
      let WireFile forms ret = parseOrFail src
      length forms `shouldBe` 2
      ret `shouldBe` Nothing

  describe "grammar §12 flagship example" $ do
    it "parses the full thesis-parallel-claim-branches program" $ do
      src <-
        TIO.readFile
          "test/fixtures/wire-v1/thesis-parallel-claim-branches.wire"
      let WireFile forms ret = parseOrFail src
      -- 7 lets + 11 nodes = 18 top forms.
      length forms `shouldBe` 18
      -- The file-return is the complete wire → @cortex.deep_report tail.
      case ret of
        Just (ExprConnect _ (ExprApply (QName ("cortex" :| ["deep_report"])) _)) ->
          pure ()
        other ->
          expectationFailure
            ("expected final => @cortex.deep_report, got: " <> show other)

isParseFailure :: Either ParseError a -> Bool
isParseFailure result = case result of
  Left _ -> True
  Right _ -> False
