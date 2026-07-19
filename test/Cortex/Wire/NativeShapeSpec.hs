{- |
Module      : Cortex.Wire.NativeShapeSpec
Description : Tests for bounded native contract representations.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These specs exercise the fixed-layout rules independently of NativePure plan
selection or executor syntax.
-}
module Cortex.Wire.NativeShapeSpec (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec

import Cortex.Wire
  ( NativeLayout (..)
  , NativeShape (..)
  , NativeShapeError (..)
  , nativeShapeLayout
  )

spec :: Spec
spec =
  describe "native_shape layouts" $ do
    it "uses fixed padding for bounded text, records, and tagged sums" $ do
      nativeShapeLayout (NativeText 5) `shouldBe` Right (NativeLayout 12 4)
      nativeShapeLayout (NativeRecord (Map.fromList [("flag", NativeBool), ("score", NativeI64)]))
        `shouldBe` Right (NativeLayout 16 8)
      nativeShapeLayout (NativeSum (Map.fromList [("none", NativeUnit), ("some", NativeI64)]))
        `shouldBe` Right (NativeLayout 16 8)

    it "rejects empty and unbounded composite representations" $ do
      nativeShapeLayout (NativeRecord Map.empty) `shouldBe` Left NativeShapeEmptyRecord
      nativeShapeLayout (NativeSum Map.empty) `shouldBe` Left NativeShapeEmptySum
      nativeShapeLayout (NativeText 0) `shouldBe` Left (NativeShapeZeroCapacity "text")
      nativeShapeLayout (NativeVector 0 NativeI64)
        `shouldBe` Left (NativeShapeZeroCapacity "vector")

    it "rejects layout overflow instead of wrapping alignment arithmetic" $ do
      let hugeVector = NativeVector 4294967295 (NativeVector 536870911 NativeU64)
          overflowRecord =
            NativeRecord
              (Map.fromList [("a", hugeVector), ("b", NativeText 4294967279), ("c", NativeU64)])
      nativeShapeLayout overflowRecord `shouldBe` Left NativeShapeLayoutOverflow
