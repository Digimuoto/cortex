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

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Test.Hspec

import Cortex.Wire
  ( NativeLayout (..)
  , NativeShape (..)
  , NativeShapeError (..)
  , NativeShapeProjection (..)
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

    it "aligns vector payloads after the length header" $ do
      nativeShapeLayout (NativeVector 2 NativeU64) `shouldBe` Right (NativeLayout 24 8)
      nativeShapeLayout (NativeVector 3 NativeBool) `shouldBe` Right (NativeLayout 8 4)
      nativeShapeLayout (NativeVector 1 (NativeText 5)) `shouldBe` Right (NativeLayout 16 4)

    it "rejects capacity products that overflow before the length header is added" $
      nativeShapeLayout (NativeVector 4294967295 (NativeVector 4294967295 NativeU64))
        `shouldBe` Left NativeShapeLayoutOverflow

    it "rejects blank record and sum labels" $ do
      nativeShapeLayout (NativeRecord (Map.fromList [("", NativeBool)]))
        `shouldBe` Left NativeShapeEmptyFieldName
      nativeShapeLayout (NativeSum (Map.fromList [(" ", NativeI64)]))
        `shouldBe` Left NativeShapeEmptyFieldName

    it "desugars option projections to the canonical two-variant sum" $ do
      let source =
            "{\"schema\":\"cortex.wire.native-shape/v1\",\"shape\":{\"kind\":\"option\",\"payload\":\"i64\"}}"
          decoded = Aeson.eitherDecode source :: Either String NativeShapeProjection
      decoded
        `shouldBe` Right
          ( NativeShapeProjection
              (NativeSum (Map.fromList [("none", NativeUnit), ("some", NativeI64)]))
          )
      case decoded of
        Right projection ->
          Aeson.eitherDecode (Aeson.encode projection) `shouldBe` Right projection
        Left decodeError -> expectationFailure decodeError
