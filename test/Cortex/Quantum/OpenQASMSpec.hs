{- |
Module      : Cortex.Quantum.OpenQASMSpec
Description : OpenQASM 3 lowering goldens for SV1 and IQM.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pins the OpenQASM 3 lowering goldens for SV1 (a native cnot) and IQM (the cnot
decomposed to h; cz; h on the target).
-}
module Cortex.Quantum.OpenQASMSpec (spec) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Quantum.OpenQASM (emitOpenQASM3)
import Cortex.Quantum.Plan (compiledCircuitToPlan, renderWalkError)
import Cortex.Quantum.TestSupport (compileText, loadTestEnv)
import Cortex.Wire.Contract (WireCompileEnv)

sv1Arn :: Text
sv1Arn = "arn:aws:braket:::device/quantum-simulator/amazon/sv1"

iqmArn :: Text
iqmArn = "arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet"

emit :: WireCompileEnv -> Text -> Text -> Either Text Text
emit env source deviceArn = do
  circuit <- compileText env source
  plan <- either (Left . renderWalkError) Right (compiledCircuitToPlan circuit)
  emitOpenQASM3 deviceArn plan

spec :: Spec
spec =
  beforeAll loadTestEnv . describe "OpenQASM 3 lowering" $ do
    it "lowers a Bell circuit for SV1 with a native cnot and full-register read" $ \env -> do
      source <- TIO.readFile "examples/wire/quantum-realize-collect.wire"
      emit env source sv1Arn
        `shouldBe` Right "OPENQASM 3;\nqubit[2] q;\nbit[2] c;\ncnot q[0], q[1];\nc = measure q;\n"

    it "lowers a Bell circuit for IQM with cnot decomposed to h; cz; h" $ \env -> do
      source <- TIO.readFile "examples/wire/quantum-realize-collect.wire"
      emit env source iqmArn
        `shouldBe` Right "OPENQASM 3;\nqubit[2] q;\nbit[2] c;\nh q[1];\ncz q[0], q[1];\nh q[1];\nc = measure q;\n"
