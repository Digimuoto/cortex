{- |
Module      : Cortex.Quantum.PlanSpec
Description : Compiled-circuit walker and realize-frontier lowering.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises the compiled-circuit walker and the realize-frontier lowering against
the native repetition-code catalog and small inline circuits, including the
zero-realize and multiple-realize rejection paths.
-}
module Cortex.Quantum.PlanSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Capability.BindingPack.Braket (BraketConfig (..), braketBindingPack)
import Cortex.Pulse.Lowering.Circuit (lrIdempotencyKey, lrPayload)
import Cortex.Pulse.Lowering.ExternalCallPayload
  ( ExternalCallOutput (..)
  , ecpOutputs
  , externalCallPayloadDigest
  )
import Cortex.Quantum.Plan
  ( Measurement (..)
  , QuantumPlan (..)
  , RealizeLowering (..)
  , WalkError (..)
  , compiledCircuitToPlan
  , lowerCompiledRealize
  , realizeNodeRef
  , renderRealizeError
  )
import Cortex.Quantum.TestSupport (compileReturn, compileText, loadTestEnv)
import Cortex.Wire
  ( CircuitNodeRef (..)
  , CircuitTaskNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Executor (WireExecutorId (..))

realizeId :: WireExecutorId
realizeId = WireExecutorId "quantum.realize"

noRealizeCircuit :: Text
noRealizeCircuit =
  "use quantum.core.{@prepare_zero, @measure_z, Qubit, Bit};\n\
  \node p -> q: Qubit = @prepare_zero { cfg = { index = 0; }; };\n\
  \node m <- q: Qubit -> b: Bit = @measure_z q;\n\
  \p => m\n"

twoRealizeCircuit :: Text
twoRealizeCircuit =
  "use quantum.core.{@prepare_zero, @cnot, @measure_z, Qubit, Bit, QuantumResult};\n\
  \use quantum.braket.{@realize};\n\
  \node pc -> control: Qubit = @prepare_zero { cfg = { index = 0; }; };\n\
  \node pt -> target: Qubit = @prepare_zero { cfg = { index = 1; }; };\n\
  \node cx\n\
  \  <- control: Qubit\n\
  \  <- target: Qubit\n\
  \  -> control: Qubit\n\
  \  -> target: Qubit\n\
  \  = @cnot { inherit control target; };\n\
  \node mc <- control: Qubit -> bc: Bit = @measure_z control;\n\
  \node mt <- target: Qubit -> bt: Bit = @measure_z target;\n\
  \node r0 <- bc: Bit -> res0: QuantumResult = @realize { inherit bc; };\n\
  \node r1 <- bt: Bit -> res1: QuantumResult = @realize { inherit bt; };\n\
  \(pc <> pt) => cx => (mc <> mt) => (r0 <> r1)\n"

fractionalIndexCircuit :: Text
fractionalIndexCircuit =
  "use quantum.core.{@prepare_zero, @measure_z, Qubit, Bit, QuantumResult};\n\
  \use quantum.braket.{@realize};\n\
  \node p -> q: Qubit = @prepare_zero { cfg = { index = 0.6; }; };\n\
  \node m <- q: Qubit -> b: Bit = @measure_z q;\n\
  \node r <- b: Bit -> result: QuantumResult = @realize { inherit b; };\n\
  \p => m => r\n"

unsupportedConfigCircuit :: Text
unsupportedConfigCircuit =
  "use quantum.core.{@prepare_zero, @measure_z, Qubit, Bit};\n\
  \node p -> q: Qubit = @prepare_zero { cfg = { index = 1 + 1; }; };\n\
  \node m <- q: Qubit -> b: Bit = @measure_z q;\n\
  \p => m\n"

sideMeasurementCircuit :: Text
sideMeasurementCircuit =
  "use quantum.core.{@prepare_zero, @cnot, @measure_z, Qubit, Bit, QuantumResult};\n\
  \use quantum.braket.{@realize};\n\
  \node pc -> control: Qubit = @prepare_zero { cfg = { index = 0; }; };\n\
  \node pt -> target: Qubit = @prepare_zero { cfg = { index = 1; }; };\n\
  \node entangle\n\
  \  <- control: Qubit\n\
  \  <- target: Qubit\n\
  \  -> control: Qubit\n\
  \  -> target: Qubit\n\
  \  = @cnot { inherit control target; };\n\
  \node mc <- control: Qubit -> bc: Bit = @measure_z control;\n\
  \node mt <- target: Qubit -> bt: Bit = @measure_z target;\n\
  \node r <- bc: Bit -> result: QuantumResult = @realize { inherit bc; };\n\
  \(pc <> pt) => entangle => (mc <> mt) => r\n"

spec :: Spec
spec =
  beforeAll loadTestEnv . describe "compiled-circuit walker and realize lowering" $ do
    it "walks the distance-3 repetition code into a five-qubit, five-measurement plan" $ \env -> do
      source <- TIO.readFile "examples/wire/qec-repetition-realize.wire"
      case compileReturn env "qec_repetition_x1" source >>= walkPlan of
        Left err -> expectationFailure (T.unpack err)
        Right plan -> do
          quantumPlanNumQubits plan `shouldBe` 5
          length (quantumPlanMeasurements plan) `shouldBe` 5

    it "lowers the realize frontier to a stable idempotency digest" $ \env -> do
      source <- TIO.readFile "examples/wire/qec-repetition-realize.wire"
      case compileReturn env "qec_repetition_x1" source >>= lowerWith of
        Left err -> expectationFailure (T.unpack err)
        Right lowering -> do
          let lowered = realizeLowered lowering
          lrIdempotencyKey lowered
            `shouldBe` "f12bb1388f6cb2d0f28d6d089b990d8d1107bea97feb5c1ffc7397d3fe5e9c3f"
          externalCallPayloadDigest (lrPayload lowered) `shouldBe` lrIdempotencyKey lowered

    it "rejects a circuit with no realize collect node" $ \env ->
      (compileText env noRealizeCircuit >>= findRealize)
        `shouldBe` Left "no realize node"

    it "rejects a circuit with more than one realize node" $ \env ->
      case compileText env twoRealizeCircuit of
        Left err -> expectationFailure (T.unpack err)
        Right circuit -> realizeNodeRef circuit `shouldSatisfy` isMultiple

    it "rejects fractional qubit indexes instead of rounding them" $ \env ->
      case compileText env fractionalIndexCircuit of
        Left err -> expectationFailure (T.unpack err)
        Right circuit ->
          case lowerWith circuit of
            Left err -> err `shouldSatisfy` T.isInfixOf "config field index must be an integer"
            Right _ -> expectationFailure "expected a fractional index validation error"

    it "rejects a non-plain cfg field with a typed error naming the field" $ \env ->
      case compileText env unsupportedConfigCircuit of
        Left err -> expectationFailure (T.unpack err)
        Right circuit ->
          compiledCircuitToPlan circuit
            `shouldBe` Left (WalkConfigUnsupportedValue "p" "cfg.index")

    it "rejects an undecodable executor argument instead of accepting the raw envelope" $ \env ->
      case compileText env noRealizeCircuit of
        Left err -> expectationFailure (T.unpack err)
        Right circuit ->
          compiledCircuitToPlan (corruptArgumentValue "p" circuit)
            `shouldBe` Left (WalkArgumentUndecodable "p")

    it "lowers only measurement bits collected by the realize node" $ \env ->
      case compileText env sideMeasurementCircuit of
        Left err -> expectationFailure (T.unpack err)
        Right circuit ->
          case lowerWith circuit of
            Left err -> expectationFailure (T.unpack err)
            Right lowering -> do
              let plan = realizePlan lowering
              fmap measurementOutput (quantumPlanMeasurements plan) `shouldBe` ["bc"]
              quantumPlanTopoOrder plan `shouldNotContain` ["mt"]
              ecpOutputs (lrPayload (realizeLowered lowering))
                `shouldBe` [ExternalCallOutput (Just "wire:0") "bc"]
  where
    pack =
      braketBindingPack
        (BraketConfig "us-east-1" "arn:aws:braket:::device/quantum-simulator/amazon/sv1" "bucket" Nothing)
    walkPlan circuit = either (Left . renderWalk) Right (compiledCircuitToPlan circuit)
    lowerWith circuit = either (Left . renderRealizeError) Right (lowerCompiledRealize pack realizeId circuit)
    findRealize circuit = either (Left . renderWalk) Right (realizeNodeRef circuit)
    isMultiple (Left (WalkMultipleRealizeNodes _)) = True
    isMultiple _ = False

renderWalk :: WalkError -> Text
renderWalk WalkNoRealizeNode = "no realize node"
renderWalk other = "walk error: " <> T.pack (show other)

{- | Replace one task node's compiled @argument.value@ metadata with a value
that is not an encoded core-pure expression, mimicking corrupted or
foreign-compiler metadata.
-}
corruptArgumentValue :: Text -> CompiledCircuit -> CompiledCircuit
corruptArgumentValue ref circuit =
  circuit
    { compiledCircuitNodes =
        Map.adjust corruptNode (CircuitNodeRef ref) (compiledCircuitNodes circuit)
    }
  where
    corruptNode node =
      case node of
        CompiledCircuitTask taskNode ->
          CompiledCircuitTask
            taskNode
              { circuitTaskNodeMetadata = corruptMetadata (circuitTaskNodeMetadata taskNode)
              }
        CompiledCircuitSignal {} -> node
        CompiledCircuitArtifact {} -> node
        CompiledCircuitRewriteBoundary {} -> node
        CompiledCircuitCondition {} -> node
    corruptMetadata metadata =
      case metadata of
        Object keyMap ->
          Object
            ( KeyMap.insert
                "argument"
                (Object (KeyMap.singleton "value" (String "not-an-expression")))
                keyMap
            )
        other -> other
