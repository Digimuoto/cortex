{- |
Module      : Cortex.Wire.NativePureDifferentialSpec
Description : NativePure differential corpus regression guards.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These specs pin the replay corpus that the hermetic Nix gate executes through
the Haskell reference, Lean evaluator, and generated C artifacts.
-}
module Cortex.Wire.NativePureDifferentialSpec (spec) where

import Data.List (nub)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire.NativePure.Differential
  ( NativePureDifferentialCase (..)
  , nativePureDifferentialCases
  , renderNativePureDifferentialInput
  , renderNativePureDifferentialTrace
  )

spec :: Spec
spec = describe "NativePure differential corpus" $ do
  it "covers checked arithmetic, sums, records, projection, and f64 identity" $ do
    length nativePureDifferentialCases `shouldBe` 18
    any isOverflow nativePureDifferentialCases `shouldBe` True
    any isClassify nativePureDifferentialCases `shouldBe` True
    any isProduct nativePureDifferentialCases `shouldBe` True
    any isProjection nativePureDifferentialCases `shouldBe` True
    length (filter isF64 nativePureDifferentialCases) `shouldBe` 5

  it "assigns unique replay inputs and canonical traces" $ do
    let inputs = fmap renderNativePureDifferentialInput nativePureDifferentialCases
        traces = fmap renderNativePureDifferentialTrace nativePureDifferentialCases
    nub inputs `shouldBe` inputs
    any (T.any (== '\t')) traces `shouldBe` False
    traces `shouldContain` ["increment:9223372036854775807 status=2"]
    traces `shouldContain` ["f64:8000000000000000 status=0 bits=8000000000000000"]

isOverflow :: NativePureDifferentialCase -> Bool
isOverflow (NativePureIncrement value) = value == maxBound
isOverflow _ = False

isClassify, isProduct, isProjection, isF64 :: NativePureDifferentialCase -> Bool
isClassify NativePureClassify {} = True
isClassify _ = False
isProduct NativePureProduct {} = True
isProduct _ = False
isProjection NativePureProjection {} = True
isProjection _ = False
isF64 NativePureF64Identity {} = True
isF64 _ = False
