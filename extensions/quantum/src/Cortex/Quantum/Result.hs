{- |
Module      : Cortex.Quantum.Result
Description : Decode an Amazon Braket task result into a correlated QuantumResult.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The realized @QuantumResult@ and its decoder. A Braket task result is decoded into
one joint histogram keyed by the full per-shot bitstring (classical bit 0 on the
right), so cross-qubit shot correlations are preserved — the joint distribution is
the histogram itself. The per-output marginal view ('outputCounts') is a projection
from it.

Two result shapes are accepted, mirroring the standalone bridge: per-shot
@measurements@ rows (preferred; preserves correlation) and a direct
@measurementCounts@/@counts@ histogram. Labels are joined from each measurement's
output port name, sorted by name for a deterministic, order-independent key.
-}
module Cortex.Quantum.Result
  ( QuantumResult (..)
  , decodeBraketResult
  , labeledKeyFor
  , labeledCounts
  , outputCounts
  , completeCounts
  , matchingShots
  , countsValue
  , labeledCountsValue
  , outputCountsValue
  , completeCountsValue
  , measurementsValue
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (testBit)
import Data.Foldable (asum, toList)
import Data.List (elemIndex, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Quantum.Plan (Measurement (..))

{- | A realized multi-shot quantum result: the joint per-shot histogram plus the
measurement records that name and order its bits.
-}
data QuantumResult = QuantumResult
  { quantumResultShots :: !Int
  , quantumResultMeasurements :: ![Measurement]
  , quantumResultCounts :: !(Map Text Int)
  }
  deriving stock (Eq, Show)

{- | Decode a Braket task result @Value@ into the joint histogram, trying the
per-shot rows first and falling back to a direct histogram.

Braket orders the per-shot measurement columns by qubit index (the result's
@measuredQubits@), not by classical-register bit. The decoder therefore maps each
measurement to its column by qubit wire, so a non-identity classical mapping — as
the forced-error QEC cases produce — decodes correctly rather than scrambling the
data and syndrome bits.
-}
decodeBraketResult :: [Measurement] -> Value -> Either Text (Map Text Int)
decodeBraketResult measurements raw
  | width <= 0 = Left "quantum result has no measurements to decode"
  | otherwise =
      case columns of
        Nothing -> Left "Braket result column ordering does not cover the measured qubits"
        Just cols ->
          case asum [findRows raw >>= countsFromRows cols, findDirectCounts cols width raw] of
            Just counts -> Right counts
            Nothing -> Left "Braket task returned an unsupported result shape"
  where
    width = length measurements
    columnOrder = fromMaybe (sortNub (map measurementWire measurements)) (findMeasuredQubits raw)
    -- For each measurement (in classical-bit order), the column index of its
    -- qubit wire within the result's column ordering.
    columns = traverse (\m -> elemIndex (measurementWire m) columnOrder) measurements

countsFromRows :: [Int] -> [Value] -> Maybe (Map Text Int)
countsFromRows cols rows =
  fmap (Map.fromListWith (+) . map (\key -> (key, 1))) (traverse (rowKey cols) rows)

rowKey :: [Int] -> Value -> Maybe Text
rowKey cols (Array row) =
  let cells = toList row
   in if any (>= length cells) cols
        then Nothing
        else do
          selected <- traverse (\col -> asBit (cells !! col)) cols
          Just (T.reverse (T.concat (map (T.pack . show) selected)))
rowKey _ _ = Nothing

directCountKeys :: [Text]
directCountKeys = ["measurementCounts", "measurement_counts", "counts"]

-- Recursively find the first @measurements@ array.
findRows :: Value -> Maybe [Value]
findRows (Object km) =
  case KeyMap.lookup "measurements" km of
    Just (Array a) -> Just (toList a)
    _ -> asum (map findRows (KeyMap.elems km))
findRows (Array a) = asum (map findRows (toList a))
findRows _ = Nothing

-- Recursively find the @measuredQubits@ column-to-qubit ordering.
findMeasuredQubits :: Value -> Maybe [Int]
findMeasuredQubits (Object km) =
  case KeyMap.lookup "measuredQubits" km of
    Just (Array a) -> traverse asIntValue (toList a)
    _ -> asum (map findMeasuredQubits (KeyMap.elems km))
findMeasuredQubits (Array a) = asum (map findMeasuredQubits (toList a))
findMeasuredQubits _ = Nothing

-- Find the first direct histogram under a known key, checking every key at each
-- nesting level before recursing into children.
findDirectCounts :: [Int] -> Int -> Value -> Maybe (Map Text Int)
findDirectCounts cols width = go
  where
    go (Object km) =
      asum
        [ normalizeCounts cols width v
        | key <- directCountKeys
        , Just v <- [KeyMap.lookup (Key.fromText key) km]
        ]
        <|> asum (map go (KeyMap.elems km))
    go (Array a) = asum (map go (toList a))
    go _ = Nothing

asIntValue :: Value -> Maybe Int
asIntValue (Number n) = case properFraction n of
  (i, f) | f == 0 -> Just (i :: Int)
  _ -> Nothing
asIntValue _ = Nothing

sortNub :: [Int] -> [Int]
sortNub = Set.toAscList . Set.fromList

normalizeCounts :: [Int] -> Int -> Value -> Maybe (Map Text Int)
normalizeCounts cols width (Object km)
  | KeyMap.null km = Nothing
  | otherwise = fmap Map.fromList (traverse entry (KeyMap.toList km))
  where
    entry (key, value) =
      let bits = T.filter (/= ' ') (Key.toText key)
       in if T.length bits == width && T.all (\c -> c == '0' || c == '1') bits
            then (,) <$> directKey cols bits <*> asCount value
            else Nothing
normalizeCounts _ _ _ = Nothing

directKey :: [Int] -> Text -> Maybe Text
directKey cols bits
  | any (>= T.length bits) cols = Nothing
  | otherwise = Just (T.reverse (T.pack [T.index bits col | col <- cols]))

asBit :: Value -> Maybe Int
asBit (Number n) =
  case properFraction n of
    (i, f) | f == 0 && i `elem` [0, 1 :: Int] -> Just i
    _ -> Nothing
asBit _ = Nothing

asCount :: Value -> Maybe Int
asCount (Number n) =
  case properFraction n of
    (i, f) | f == 0 -> Just (i :: Int)
    _ -> Nothing
asCount _ = Nothing

{- | The bit a measurement contributes to a joint bitstring (classical bit 0 on
the right).
-}
bitAt :: Int -> Text -> Int -> Char
bitAt width bits classicalBit = T.index bits (width - 1 - classicalBit)

{- | The deterministic label for a joint bitstring: @output=bit@ pairs sorted by
output name.
-}
labeledKeyFor :: [Measurement] -> Text -> Text
labeledKeyFor measurements bits =
  T.intercalate
    ","
    [ measurementOutput m <> "=" <> T.singleton (bitAt width bits (measurementClassicalBit m))
    | m <- sortOn measurementOutput measurements
    ]
  where
    width = length measurements

-- | Group the joint histogram by labeled outcome.
labeledCounts :: QuantumResult -> Map Text Int
labeledCounts result =
  Map.fromListWith
    (+)
    [ (labeledKeyFor (quantumResultMeasurements result) bits, count)
    | (bits, count) <- Map.toList (quantumResultCounts result)
    ]

-- | The marginal per-output @(zeros, ones)@ tallies (loses correlation).
outputCounts :: QuantumResult -> Map Text (Int, Int)
outputCounts result =
  Map.fromListWith
    addPair
    [ (measurementOutput m, tally (bitAt width bits (measurementClassicalBit m)) count)
    | (bits, count) <- Map.toList (quantumResultCounts result)
    , m <- measurements
    ]
  where
    measurements = quantumResultMeasurements result
    width = length measurements
    tally '1' count = (0, count)
    tally _ count = (count, 0)
    addPair (z1, o1) (z2, o2) = (z1 + z2, o1 + o2)

-- | The dense histogram over every @2^width@ bitstring.
completeCounts :: QuantumResult -> Map Text Int
completeCounts result =
  Map.fromList
    [ (bitstring, Map.findWithDefault 0 bitstring counts)
    | i <- [0 .. 2 ^ width - 1]
    , let bitstring = binaryString width i
    ]
  where
    counts = quantumResultCounts result
    width = length (quantumResultMeasurements result)

binaryString :: Int -> Int -> Text
binaryString width i =
  T.pack [if testBit i b then '1' else '0' | b <- [width - 1, width - 2 .. 0]]

-- | The shot count landing exactly on the expected labeled outcome.
matchingShots :: QuantumResult -> Text -> Int
matchingShots result expected =
  Map.findWithDefault 0 expected (labeledCounts result)

-- JSON projections for the runner result object.

countsValue :: Map Text Int -> Value
countsValue = toJSON

labeledCountsValue :: QuantumResult -> Value
labeledCountsValue = toJSON . labeledCounts

outputCountsValue :: QuantumResult -> Value
outputCountsValue result =
  toJSON (Map.map (\(z, o) -> object ["0" .= z, "1" .= o]) (outputCounts result))

completeCountsValue :: QuantumResult -> Value
completeCountsValue = toJSON . completeCounts

measurementsValue :: [Measurement] -> Value
measurementsValue measurements =
  toJSON
    [ object
        [ "node" .= measurementNode m
        , "wire" .= measurementWire m
        , "classical_bit" .= measurementClassicalBit m
        , "output" .= measurementOutput m
        ]
    | m <- measurements
    ]
