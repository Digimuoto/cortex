{- |
Module      : Cortex.Quantum.OpenQASM
Description : Lower a fused quantum plan to OpenQASM 3 for Amazon Braket.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The backend-specific lowering of a 'QuantumPlan' to an OpenQASM 3 program for
Amazon Braket. The emission is a deterministic function of the topologically
ordered operation stream:

* @\@prepare_zero@ is implicit (qubits start in @|0>@) and emits nothing;
* @\@sx@ lowers to the OpenQASM @v@ (square-root-X) gate;
* @\@rz@ with a (near-)zero angle is dropped;
* on IQM devices (any @\/qpu\/iqm\/@ ARN) @cnot@ is decomposed to @h; cz; h@ on
  the target, with a peephole that cancels back-to-back Hadamards;
* a terminal measurement is deferred to the end of the program unless its wire is
  gated again afterwards (a mid-circuit measurement), in which case it is emitted
  inline.

When the register is fully and identically measured the whole register is read in
one @c = measure q;@ statement; otherwise each classical bit is measured
explicitly.
-}
module Cortex.Quantum.OpenQASM
  ( emitOpenQASM3
  )
where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Quantum.Plan
  ( Measurement (..)
  , PlanOp (..)
  , QuantumPlan (..)
  )

{- | Lower a quantum plan to an OpenQASM 3 program for the given device ARN, or
fail if the plan declares no measurements.
-}
emitOpenQASM3 :: Text -> QuantumPlan -> Either Text Text
emitOpenQASM3 deviceArn plan
  | null measurements = Left "Amazon Braket execution requires at least one measurement"
  | otherwise = Right (T.intercalate "\n" (reverse finalLines) <> "\n")
  where
    measurements = quantumPlanMeasurements plan
    ops = quantumPlanOps plan
    numQubits = quantumPlanNumQubits plan
    viaCz = "/qpu/iqm/" `T.isInfixOf` T.toLower deviceArn

    lastGateUse :: Map Int Int
    lastGateUse =
      foldl'
        (\acc (ix, op) -> foldl' (\m wire -> Map.insert wire ix m) acc (nonMeasureWires op))
        Map.empty
        (zip [0 ..] ops)

    measuredWires = Set.fromList (map measurementWire measurements)
    extraMeasurements = [w | w <- quantumPlanQubits plan, w `Set.notMember` measuredWires]
    classicalBits = length measurements + length extraMeasurements

    header =
      [ "bit[" <> tshow classicalBits <> "] c;"
      , "qubit[" <> tshow numQubits <> "] q;"
      , "OPENQASM 3;"
      ]

    -- @revLines@ is the program built in reverse; @deferred@ collects terminal
    -- measurements to emit after all gates.
    (bodyLines, deferred) = foldl' emit (header, []) (zip [0 ..] ops)

    finalLines =
      if canMeasureFullRegister measurements deferred extraMeasurements numQubits
        then "c = measure q;" : bodyLines
        else
          let offset = length measurements
              deferredLines =
                [ measureLine (measurementClassicalBit m) (measurementWire m)
                | m <- sortOn measurementClassicalBit deferred
                ]
              extraLines =
                [ measureLine (offset + i) wire
                | (i, wire) <- zip [0 ..] extraMeasurements
                ]
           in reverse (deferredLines <> extraLines) <> bodyLines

    emit (revLines, def) (ix, op) =
      case op of
        OpPrepareZero {} -> (revLines, def)
        OpGate1 _ "h" wire -> (gate1 "h" wire : revLines, def)
        OpGate1 _ "sx" wire -> (gate1 "v" wire : revLines, def)
        OpGate1 _ "x" wire -> (gate1 "x" wire : revLines, def)
        OpGate1 _ other wire -> (gate1 other wire : revLines, def)
        OpRz _ wire angle
          | abs angle < 1e-15 -> (revLines, def)
          | otherwise -> ("rz(" <> tshow angle <> ") " <> qubit wire <> ";" : revLines, def)
        OpGate2 _ "cz" control target -> ("cz " <> qubit control <> ", " <> qubit target <> ";" : revLines, def)
        OpGate2 _ _ control target -> (appendCnot control target revLines, def)
        OpMeasureZ m
          | ix >= Map.findWithDefault (-1) (measurementWire m) lastGateUse -> (revLines, m : def)
          | otherwise -> (measureLine (measurementClassicalBit m) (measurementWire m) : revLines, def)

    appendCnot control target revLines
      | not viaCz = ("cnot " <> qubit control <> ", " <> qubit target <> ";") : revLines
      | otherwise =
          let afterFirstH = appendSelfInverseH target revLines
              afterCz = ("cz " <> qubit control <> ", " <> qubit target <> ";") : afterFirstH
           in appendSelfInverseH target afterCz

    appendSelfInverseH wire revLines =
      let line = gate1 "h" wire
       in case revLines of
            (top : rest) | top == line -> rest
            _ -> line : revLines

    gate1 g wire = g <> " " <> qubit wire <> ";"
    measureLine classicalBit wire = "c[" <> tshow classicalBit <> "] = measure " <> qubit wire <> ";"
    qubit wire = "q[" <> tshow wire <> "]"

nonMeasureWires :: PlanOp -> [Int]
nonMeasureWires = \case
  OpPrepareZero _ wire _ -> [wire]
  OpGate1 _ _ wire -> [wire]
  OpRz _ wire _ -> [wire]
  OpGate2 _ _ control target -> [control, target]
  OpMeasureZ _ -> []

canMeasureFullRegister :: [Measurement] -> [Measurement] -> [Int] -> Int -> Bool
canMeasureFullRegister measurements deferred extra numQubits =
  null extra
    && length deferred == length measurements
    && length measurements == numQubits
    && all (\m -> measurementClassicalBit m == measurementWire m) measurements

tshow :: Show a => a -> Text
tshow = T.pack . show
