{- |
Module      : Cortex.Quantum.ResultSpec
Description : Braket result decoding and labeled-outcome views.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Checks the Braket result decoder and the labeled-outcome views over per-shot rows
and direct histograms, including bit-order and width-mismatch handling.
-}
module Cortex.Quantum.ResultSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec

import Cortex.Quantum.Plan (Measurement (..))
import Cortex.Quantum.Result
  ( QuantumResult (..)
  , decodeBraketResult
  , labeledKeyFor
  , matchingShots
  )

measurements :: [Measurement]
measurements = [Measurement "m0" 0 0 "a", Measurement "m1" 1 1 "b"]

rowsResult :: Value
rowsResult = object ["measurements" .= ([[0, 1], [1, 0]] :: [[Int]])]

countsResult :: Value
countsResult = object ["measurementCounts" .= object ["01" .= (5 :: Int), "10" .= (3 :: Int)]]

badWidthResult :: Value
badWidthResult = object ["measurementCounts" .= object ["0" .= (1 :: Int)]]

spec :: Spec
spec =
  describe "Braket result decoding" $ do
    it "decodes per-shot rows into a joint histogram (classical bit 0 on the right)" $
      decodeBraketResult measurements rowsResult
        `shouldBe` Right (Map.fromList [("01", 1), ("10", 1)])

    it "decodes a direct measurementCounts histogram" $
      decodeBraketResult measurements countsResult
        `shouldBe` Right (Map.fromList [("10", 5), ("01", 3)])

    it "rejects a histogram whose bitstring width does not match the measurements" $
      decodeBraketResult measurements badWidthResult `shouldSatisfy` isLeft

    it "labels a joint outcome by output name, sorted" $
      labeledKeyFor measurements "01" `shouldBe` "a=1,b=0"

    it "counts shots landing on an expected labeled outcome" $
      let result = QuantumResult 4 measurements (Map.fromList [("01", 3), ("10", 1)])
       in matchingShots result (labeledKeyFor measurements "01") `shouldBe` 3

    it "maps result columns by qubit index (measuredQubits), not classical bit" $
      -- Output a is on qubit 3 (classical bit 0); output b is on qubit 0
      -- (classical bit 1). The row [q0=1, q3=0] must decode to a=0, b=1.
      let permuted = [Measurement "ma" 3 0 "a", Measurement "mb" 0 1 "b"]
          rows = object ["measuredQubits" .= ([0, 3] :: [Int]), "measurements" .= ([[1, 0]] :: [[Int]])]
       in case decodeBraketResult permuted rows of
            Left err -> expectationFailure (T.unpack err)
            Right counts -> matchingShots (QuantumResult 1 permuted counts) "a=0,b=1" `shouldBe` 1

    it "maps direct histogram keys by measuredQubits before labeling" $
      -- Direct histograms use the provider's measuredQubits column order just
      -- like per-shot rows. This nontrivial permutation would decode as "100"
      -- if the fallback kept the provider key unchanged; the internal bitstring
      -- is "010", with classical bit 0 on the right.
      let permuted =
            [ Measurement "ma" 2 0 "a"
            , Measurement "mb" 0 1 "b"
            , Measurement "mc" 1 2 "c"
            ]
          counts =
            object
              [ "measuredQubits" .= ([0, 1, 2] :: [Int])
              , "counts" .= object ["100" .= (7 :: Int)]
              ]
       in decodeBraketResult permuted counts
            `shouldBe` Right (Map.fromList [("010", 7)])
