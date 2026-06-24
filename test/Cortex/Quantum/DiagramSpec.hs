{- |
Module      : Cortex.Quantum.DiagramSpec
Description : Qiskit-style circuit diagram rendering.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Checks the Unicode circuit-diagram renderer against the compiled distance-3
repetition code (non-adjacent CNOT crossings) and small hand-built edge cases,
plus the layout invariants the Markdown fence relies on.
-}
module Cortex.Quantum.DiagramSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Quantum.Diagram (renderCircuitDiagram)
import Cortex.Quantum.Plan
  ( Measurement (..)
  , PlanOp (..)
  , QuantumPlan (..)
  , compiledCircuitToPlan
  , renderWalkError
  )
import Cortex.Quantum.TestSupport (compileReturn, compileText, loadTestEnv)

noTrailingSpace :: Text -> Bool
noTrailingSpace d = all (\l -> l == T.stripEnd l) (T.lines d)

spec :: Spec
spec =
  beforeAll loadTestEnv . describe "circuit diagram" $ do
    it "renders the x1 repetition code with crossing CNOT connectors" $ \env -> do
      source <- TIO.readFile "examples/wire/qec-repetition-realize.wire"
      case compileReturn env "qec_repetition_x1" source >>= toPlan of
        Left err -> expectationFailure (T.unpack err)
        Right plan -> do
          let d = renderCircuitDiagram plan
          d `shouldSatisfy` (\t -> not (T.null t) && T.last t /= '\n')
          d `shouldSatisfy` (not . T.isPrefixOf "\n")
          d `shouldSatisfy` noTrailingSpace
          d `shouldSatisfy` T.isInfixOf "q_0: "
          d `shouldSatisfy` T.isInfixOf "┤X├" -- the injected X gate
          d `shouldSatisfy` T.isInfixOf "●" -- a CNOT control
          d `shouldSatisfy` T.isInfixOf "┼" -- a crossing over an intervening wire
          d `shouldSatisfy` T.isInfixOf "┤M├" -- terminal measurements
          length (T.lines d) `shouldBe` 11 -- 5 lanes + 4 inner + bottom connector + classical
    it "renders the Bell circuit exactly (golden)" $ \env -> do
      source <- TIO.readFile "examples/wire/quantum-realize-collect.wire"
      case compileText env source >>= toPlan of
        Left err -> expectationFailure (T.unpack err)
        Right plan ->
          renderCircuitDiagram plan
            `shouldBe` "q_0: ──●───┤M├──────\n       │    ║\nq_1: ──X────╫───┤M├─\n            ║    ║\n  c:        0    1"

    it "renders a single measured qubit with no connectors" $ \_ -> do
      let plan = QuantumPlan ["m"] 1 [0] [OpMeasureZ (Measurement "m" 0 0 "b")] [Measurement "m" 0 0 "b"]
          d = renderCircuitDiagram plan
      d `shouldSatisfy` T.isInfixOf "┤M├"
      d `shouldSatisfy` (not . T.isInfixOf "┼")

    it "draws a cz as two control dots and no target box" $ \_ -> do
      let plan =
            QuantumPlan
              ["p"]
              2
              [0, 1]
              [OpGate2 "g" "cz" 0 1, OpMeasureZ (Measurement "m0" 0 0 "a"), OpMeasureZ (Measurement "m1" 1 1 "b")]
              [Measurement "m0" 0 0 "a", Measurement "m1" 1 1 "b"]
          d = renderCircuitDiagram plan
      length (T.splitOn "●" d) `shouldBe` 3 -- two control dots
      d `shouldSatisfy` (not . T.isInfixOf "┤X├")
  where
    toPlan circuit = either (Left . renderWalkError) Right (compiledCircuitToPlan circuit)
